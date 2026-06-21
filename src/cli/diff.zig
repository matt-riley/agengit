const std = @import("std");
const config_mod = @import("../store/config.zig");
const diff_mod = @import("../store/diff.zig");
const inspect_mod = @import("../store/inspect.zig");
const redact_mod = @import("../privacy/redact.zig");
const session_arg = @import("session_arg.zig");
const snapshot_mod = @import("../store/snapshot.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const store_mod = @import("../store/store.zig");
const arg_parse = @import("arg_parse.zig");

pub const usage = specs.diff_usage;

const default_display_max_bytes: u64 = 16 * 1024 * 1024;

const RedactionMode = enum {
    auto,
    redacted,
    full,
};

const DiffOptions = struct {
    format: output_mod.Format = .human,
    left_hash_prefix: ?[:0]const u8 = null,
    right_hash_prefix: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,
    path: ?[:0]const u8 = null,
    redaction_mode: RedactionMode = .auto,
};

const BaselineKind = enum {
    parent_tree,
    empty_tree,
    step_tree,
};

const Endpoint = struct {
    tree_hash: []const u8,
    step_hash: ?[]const u8 = null,
};

const DiffContext = struct {
    from: Endpoint,
    to: Endpoint,
    baseline: BaselineKind,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

const RenderedBlob = struct {
    text: []u8 = &.{},
    skip_reason: ?[]u8 = null,

    fn deinit(self: *RenderedBlob, gpa: std.mem.Allocator) void {
        if (self.text.len > 0) gpa.free(self.text);
        if (self.skip_reason) |reason| gpa.free(reason);
        self.* = undefined;
    }
};

const JsonChange = struct {
    kind: []const u8,
    path: []const u8,
    old_blob: ?[]const u8,
    new_blob: ?[]const u8,
    old_size: ?u64,
    new_size: ?u64,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        error.InvalidArgument => return,
        else => return err,
    };

    if (options.session == null and options.left_hash_prefix == null) {
        try missingTarget(&stdout, options.format);
        return;
    }
    if (options.session != null and (options.left_hash_prefix != null or options.right_hash_prefix != null)) {
        try arg_parse.invalidArg(&stdout, options.format, usage, "--session cannot be combined with step hash arguments.");
        return;
    }

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_config",
            .message = "Failed to load .agit/config.json.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer loaded_config.deinit();
    const use_redaction = shouldUseRedaction(options.redaction_mode, loaded_config.value.privacy.display.redacted_by_default);

    var context = try resolveDiffContext(io, gpa, &store, &stdout, options);
    defer context.deinit();

    var from_tree: ?std.json.Parsed(store_mod.Tree) = null;
    defer if (from_tree) |*tree| tree.deinit();
    var to_tree = readTreeFromHex(io, gpa, &store, context.value.to.tree_hash, options.format, &stdout);
    defer to_tree.deinit();

    const old_entries = if (std.mem.eql(u8, context.value.from.tree_hash, ""))
        &.{}
    else blk: {
        from_tree = readTreeFromHex(io, gpa, &store, context.value.from.tree_hash, options.format, &stdout);
        break :blk from_tree.?.value.entries;
    };

    var comparison = inspect_mod.compareTreeEntries(gpa, old_entries, to_tree.value.entries) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "tree_compare_failed",
            .message = "Failed to compare step trees.",
            .hint = @errorName(err),
            .hash = context.value.to.tree_hash,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer comparison.deinit(gpa);

    switch (options.format) {
        .human => try writeHuman(
            io,
            gpa,
            &stdout,
            &store,
            options,
            comparison.entries,
            use_redaction,
            loaded_config.value.privacy.custom_literals,
        ),
        .json => {
            const changes = try buildJsonChanges(gpa, comparison.entries);
            defer gpa.free(changes);
            try output_mod.writeEnvelope(&stdout, usage.name, .{
                .from = .{
                    .tree = if (context.value.from.tree_hash.len == 0) null else context.value.from.tree_hash,
                    .step = context.value.from.step_hash,
                },
                .to = .{
                    .tree = context.value.to.tree_hash,
                    .step = context.value.to.step_hash,
                },
                .baseline = @tagName(context.value.baseline),
                .origin = context.value.origin,
                .session_id = context.value.session_id,
                .path = options.path,
                .redacted = use_redaction,
                .counts = comparison.counts,
                .changes = changes,
            });
        },
    }
    try stdout.flush();
}

const ParsedContext = struct {
    gpa: std.mem.Allocator,
    value: DiffContext,
    parsed_left: ?std.json.Parsed(store_mod.Step) = null,
    parsed_right: ?std.json.Parsed(store_mod.Step) = null,
    parsed_parent: ?std.json.Parsed(store_mod.Step) = null,
    owned_strings: std.ArrayList([]const u8) = .empty,

    fn init(gpa: std.mem.Allocator, value: DiffContext) ParsedContext {
        return .{
            .gpa = gpa,
            .value = value,
        };
    }

    fn own(self: *ParsedContext, value: []const u8) ![]const u8 {
        const owned = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(owned);
        try self.owned_strings.append(self.gpa, owned);
        return owned;
    }

    fn deinit(self: *ParsedContext) void {
        if (self.parsed_left) |*parsed| parsed.deinit();
        if (self.parsed_right) |*parsed| parsed.deinit();
        if (self.parsed_parent) |*parsed| parsed.deinit();
        for (self.owned_strings.items) |owned| self.gpa.free(owned);
        self.owned_strings.deinit(self.gpa);
        self.* = undefined;
    }
};

fn resolveDiffContext(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    stdout: *std.Io.File.Writer,
    options: DiffOptions,
) !ParsedContext {
    if (options.session) |session| {
        const target = try session_arg.resolveExisting(gpa, store, stdout, options.format, usage.name, session);
        defer target.deinit(gpa);
        const steps = try store.index.listSteps(gpa, target.origin, target.session_id);
        defer store_mod.freeStepRows(gpa, steps);
        if (steps.len == 0) {
            try status.writeDiagnostic(stdout, options.format, usage.name, .{
                .code = "session_has_no_steps",
                .message = "Session has no recorded steps.",
                .hint = "Run `agit log <origin>/<session-id>` to inspect the session.",
                .path = session,
            });
            try stdout.flush();
            std.process.exit(1);
        }

        var result = ParsedContext.init(gpa, .{
            .from = .{ .tree_hash = "" },
            .to = .{
                .tree_hash = "",
                .step_hash = null,
            },
            .baseline = .empty_tree,
            .origin = null,
            .session_id = null,
        });
        errdefer result.deinit();
        result.value.to.tree_hash = try result.own(steps[steps.len - 1].tree_hash);
        result.value.to.step_hash = try result.own(steps[steps.len - 1].hash);
        result.value.origin = try result.own(target.origin);
        result.value.session_id = try result.own(target.session_id);
        if (steps[0].parent_hash) |parent_hash_hex| {
            const parent_hash = parseHashOrExit(stdout, options.format, parent_hash_hex, "invalid_parent_hash", "Step parent hash is invalid.");
            result.parsed_parent = readStepByHash(io, gpa, store, stdout, options.format, parent_hash, parent_hash_hex);
            result.value.from = .{
                .tree_hash = result.parsed_parent.?.value.tree,
                .step_hash = try result.own(parent_hash_hex),
            };
            result.value.baseline = .parent_tree;
        }
        return result;
    }

    const left_prefix = options.left_hash_prefix.?;
    var left = try readStepFromPrefix(io, gpa, store, stdout, options.format, left_prefix);
    errdefer left.deinit(gpa);
    defer gpa.free(left.hash);
    if (options.right_hash_prefix) |right_prefix| {
        var right = try readStepFromPrefix(io, gpa, store, stdout, options.format, right_prefix);
        errdefer right.deinit(gpa);
        defer gpa.free(right.hash);
        var result = ParsedContext.init(gpa, .{
            .from = .{
                .tree_hash = left.parsed.value.tree,
                .step_hash = null,
            },
            .to = .{
                .tree_hash = right.parsed.value.tree,
                .step_hash = null,
            },
            .baseline = .step_tree,
        });
        errdefer result.deinit();
        result.value.from.step_hash = try result.own(left.hash);
        result.value.to.step_hash = try result.own(right.hash);
        result.parsed_left = left.parsed;
        result.parsed_right = right.parsed;
        return result;
    }

    var result = ParsedContext.init(gpa, .{
        .from = .{ .tree_hash = "" },
        .to = .{
            .tree_hash = left.parsed.value.tree,
            .step_hash = null,
        },
        .baseline = .empty_tree,
    });
    errdefer result.deinit();
    result.value.to.step_hash = try result.own(left.hash);
    result.parsed_left = left.parsed;
    if (left.parsed.value.parent) |parent_hash_hex| {
        const parent_hash = parseHashOrExit(stdout, options.format, parent_hash_hex, "invalid_parent_hash", "Step parent hash is invalid.");
        result.parsed_parent = readStepByHash(io, gpa, store, stdout, options.format, parent_hash, parent_hash_hex);
        result.value.from = .{
            .tree_hash = result.parsed_parent.?.value.tree,
            .step_hash = try result.own(parent_hash_hex),
        };
        result.value.baseline = .parent_tree;
    }
    return result;
}

const ResolvedStep = struct {
    hash: []const u8,
    parsed: std.json.Parsed(store_mod.Step),

    fn deinit(self: *ResolvedStep, gpa: std.mem.Allocator) void {
        gpa.free(self.hash);
        self.parsed.deinit();
        self.* = undefined;
    }
};

fn readStepFromPrefix(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    prefix: []const u8,
) !ResolvedStep {
    const resolution = store.resolvePrefix(io, gpa, prefix) catch |err| {
        try status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "object_lookup_failed",
            .message = "Failed to resolve object prefix.",
            .hint = @errorName(err),
            .hash = prefix,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    const step_hash = switch (resolution) {
        .not_found => {
            try status.writeDiagnostic(stdout, format, usage.name, .{
                .code = "object_not_found",
                .message = "Object not found.",
                .hint = "Use a longer or different hash prefix.",
                .hash = prefix,
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .ambiguous => |matches| {
            var candidate_hex: [2][64]u8 = .{ matches[0].toHex(), matches[1].toHex() };
            if (std.mem.lessThan(u8, candidate_hex[1][0..], candidate_hex[0][0..])) {
                std.mem.swap([64]u8, &candidate_hex[0], &candidate_hex[1]);
            }
            const candidates = [_][]const u8{ candidate_hex[0][0..], candidate_hex[1][0..] };
            try status.writeDiagnostic(stdout, format, usage.name, .{
                .code = "ambiguous_hash_prefix",
                .message = "Hash prefix is ambiguous.",
                .hint = "Use a longer hash prefix.",
                .hash = prefix,
                .candidates = candidates[0..],
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .unique => |resolved| resolved,
    };
    const hex = step_hash.toHex();
    return .{
        .hash = try gpa.dupe(u8, hex[0..]),
        .parsed = readStepByHash(io, gpa, store, stdout, format, step_hash, hex[0..]),
    };
}

fn readStepByHash(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    step_hash: store_mod.Hash,
    hex: []const u8,
) std.json.Parsed(store_mod.Step) {
    return store.readStep(io, gpa, step_hash) catch |err| {
        const diagnostic: output_mod.Diagnostic = switch (err) {
            error.UnknownField,
            error.InvalidCharacter,
            error.UnexpectedToken,
            error.InvalidNumber,
            error.Overflow,
            error.InvalidEnumTag,
            error.DuplicateField,
            error.MissingField,
            error.LengthMismatch,
            error.SyntaxError,
            => .{
                .code = "invalid_step_object",
                .message = "Object is not a step.",
                .hash = hex,
            },
            else => .{
                .code = "step_read_failed",
                .message = "Failed to read step object.",
                .hint = @errorName(err),
                .hash = hex,
            },
        };
        status.writeDiagnostic(stdout, format, usage.name, diagnostic) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
}

fn buildJsonChanges(gpa: std.mem.Allocator, entries: []const inspect_mod.ComparedEntry) ![]const JsonChange {
    var list: std.ArrayList(JsonChange) = .empty;
    errdefer list.deinit(gpa);
    for (entries) |entry| {
        if (entry.kind == .unchanged) continue;
        try list.append(gpa, .{
            .kind = @tagName(entry.kind),
            .path = entry.path,
            .old_blob = if (entry.old_entry) |old| old.blob else null,
            .new_blob = if (entry.new_entry) |new| new.blob else null,
            .old_size = if (entry.old_entry) |old| old.size else null,
            .new_size = if (entry.new_entry) |new| new.size else null,
        });
    }
    return list.toOwnedSlice(gpa);
}

fn writeHuman(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    options: DiffOptions,
    compared_entries: []const inspect_mod.ComparedEntry,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !void {
    const explicit_path = options.path;
    const max_display_bytes = default_display_max_bytes;

    var rendered_any = false;
    var matched_path = false;
    for (compared_entries) |entry| {
        if (explicit_path) |path| {
            if (!std.mem.eql(u8, entry.path, path)) continue;
            matched_path = true;
        } else if (entry.kind == .unchanged) {
            continue;
        }

        if (entry.kind == .unchanged) continue;
        if (rendered_any) try stdout.interface.writeAll("\n");
        rendered_any = true;

        var old_blob = try readRenderedBlob(io, gpa, store, entry.old_entry, max_display_bytes, use_redaction, custom_literals);
        defer old_blob.deinit(gpa);
        var new_blob = try readRenderedBlob(io, gpa, store, entry.new_entry, max_display_bytes, use_redaction, custom_literals);
        defer new_blob.deinit(gpa);

        try writeDiffHeader(stdout, entry);

        const reason = old_blob.skip_reason orelse new_blob.skip_reason;
        if (reason) |skip_reason| {
            try stdout.interface.print("@@ skipped: {s} @@\n", .{skip_reason});
            continue;
        }

        const old_lines = try splitLinesAlloc(gpa, old_blob.text);
        defer gpa.free(old_lines);
        const new_lines = try splitLinesAlloc(gpa, new_blob.text);
        defer gpa.free(new_lines);

        const edits = try diff_mod.diff(gpa, old_lines, new_lines);
        defer gpa.free(edits);

        var visible_changes: usize = 0;
        for (edits) |edit| {
            const prefix: u8 = switch (edit.op) {
                .equal => ' ',
                .insert => '+',
                .delete => '-',
            };
            switch (edit.op) {
                .insert, .delete => visible_changes += 1,
                .equal => {},
            }
            try stdout.interface.print("{c}{s}\n", .{ prefix, edit.line });
        }
        if (visible_changes == 0) {
            try stdout.interface.writeAll("  (no visible text changes after redaction)\n");
        }
    }

    if (explicit_path) |path| {
        if (!matched_path) {
            try stdout.interface.print("Path {s} was not captured in this diff.\n", .{path});
            return;
        }
    }
    if (!rendered_any) {
        try stdout.interface.writeAll("No file changes captured in this diff.\n");
    }
}

fn writeDiffHeader(stdout: *std.Io.File.Writer, entry: inspect_mod.ComparedEntry) !void {
    const path = entry.path;
    try stdout.interface.print("diff --git a/{s} b/{s}\n", .{ path, path });
    switch (entry.kind) {
        .added => {
            try stdout.interface.print("--- /dev/null\n", .{});
            try stdout.interface.print("+++ b/{s}\n", .{path});
        },
        .deleted => {
            try stdout.interface.print("--- a/{s}\n", .{path});
            try stdout.interface.print("+++ /dev/null\n", .{});
        },
        .modified, .unchanged => {
            try stdout.interface.print("--- a/{s}\n", .{path});
            try stdout.interface.print("+++ b/{s}\n", .{path});
        },
    }
}

fn readRenderedBlob(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    entry: ?store_mod.TreeEntry,
    max_display_bytes: u64,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !RenderedBlob {
    const resolved_entry = entry orelse return .{};
    if (resolved_entry.size > max_display_bytes) {
        return .{
            .skip_reason = try std.fmt.allocPrint(gpa, "captured file exceeds the diff size cap ({d} bytes)", .{
                max_display_bytes,
            }),
        };
    }

    const blob_hash = try store_mod.Hash.fromHex(resolved_entry.blob);
    const raw = try store.readBlob(io, gpa, blob_hash);
    errdefer gpa.free(raw);
    if (raw.len > max_display_bytes) {
        gpa.free(raw);
        return .{
            .skip_reason = try std.fmt.allocPrint(gpa, "blob payload exceeds the diff size cap ({d} bytes)", .{
                max_display_bytes,
            }),
        };
    }
    if (snapshot_mod.isBinary(raw)) {
        gpa.free(raw);
        return .{
            .skip_reason = try gpa.dupe(u8, "binary content is not diffed"),
        };
    }

    if (!use_redaction) {
        return .{ .text = raw };
    }

    const redacted = try redact_mod.redactAlloc(gpa, raw, .{
        .custom_literals = custom_literals,
    });
    gpa.free(raw);
    return .{ .text = redacted };
}

fn splitLinesAlloc(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);

    var iter = std.mem.splitScalar(u8, text, '\n');
    while (iter.next()) |line| {
        try lines.append(gpa, std.mem.trimEnd(u8, line, "\r"));
    }
    return lines.toOwnedSlice(gpa);
}

fn readTreeFromHex(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    tree_hash_hex: []const u8,
    format: output_mod.Format,
    stdout: *std.Io.File.Writer,
) std.json.Parsed(store_mod.Tree) {
    const tree_hash = store_mod.Hash.fromHex(tree_hash_hex) catch {
        status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "invalid_tree_hash",
            .message = "Step tree hash is invalid.",
            .hash = tree_hash_hex,
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
    return store.readTree(io, gpa, tree_hash) catch |err| {
        status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "tree_read_failed",
            .message = "Failed to read step tree.",
            .hint = @errorName(err),
            .hash = tree_hash_hex,
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
}

fn parseHashOrExit(
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    hex: []const u8,
    code: []const u8,
    message: []const u8,
) store_mod.Hash {
    return store_mod.Hash.fromHex(hex) catch {
        status.writeDiagnostic(stdout, format, usage.name, .{
            .code = code,
            .message = message,
            .hash = hex,
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !DiffOptions {
    var options: DiffOptions = .{};
    var path_mode = false;
    while (iter.next()) |arg| {
        if (path_mode) {
            if (options.path != null) {
                try arg_parse.invalidArg(stdout, options.format, usage, "Only one path may follow `--`.");
                return error.InvalidArgument;
            }
            options.path = arg;
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            path_mode = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--session")) {
            options.session = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--session requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--redacted")) {
            options.redaction_mode = .redacted;
        } else if (std.mem.eql(u8, arg, "--full")) {
            options.redaction_mode = .full;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (options.left_hash_prefix == null) {
            options.left_hash_prefix = arg;
        } else if (options.right_hash_prefix == null) {
            options.right_hash_prefix = arg;
        } else {
            try arg_parse.invalidArg(stdout, options.format, usage, "Unexpected argument.");
            return error.InvalidArgument;
        }
    }

    if (path_mode and options.path == null) {
        try arg_parse.invalidArg(stdout, options.format, usage, "`--` must be followed by a captured path.");
        return error.InvalidArgument;
    }
    return options;
}

fn missingTarget(stdout: *std.Io.File.Writer, format: output_mod.Format) !void {
    if (format == .json) {
        try status.writeDiagnostic(stdout, .json, usage.name, .{
            .code = "missing_target",
            .message = "A step hash or --session value is required.",
        });
    } else {
        try help_mod.renderUsage(stdout, usage);
    }
    try stdout.flush();
    std.process.exit(1);
}

fn shouldUseRedaction(mode: RedactionMode, redacted_by_default: bool) bool {
    return switch (mode) {
        .auto => redacted_by_default,
        .redacted => true,
        .full => false,
    };
}

const std = @import("std");
const config_mod = @import("../store/config.zig");
const diff_mod = @import("../store/diff.zig");
const inspect_mod = @import("../store/inspect.zig");
const redact_mod = @import("../privacy/redact.zig");
const snapshot_mod = @import("../store/snapshot.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const specs = @import("specs.zig");
const store_mod = @import("../store/store.zig");

pub const usage = specs.diff_usage;

const default_display_max_bytes: u64 = 16 * 1024 * 1024;

const RedactionMode = enum {
    auto,
    redacted,
    full,
};

const DiffOptions = struct {
    hash_prefix: ?[:0]const u8 = null,
    path: ?[:0]const u8 = null,
    redaction_mode: RedactionMode = .auto,
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

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        error.InvalidArgument => return,
        else => return err,
    };

    const prefix = options.hash_prefix orelse {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        std.process.exit(1);
    };

    var store = try status.openStoreOrExit(io, gpa, &stdout, .human, usage.name);
    defer store.deinit(io);

    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
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

    const resolution = store.resolvePrefix(io, gpa, prefix) catch |err| {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
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
            try status.writeDiagnostic(&stdout, .human, usage.name, .{
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
            try status.writeDiagnostic(&stdout, .human, usage.name, .{
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

    var parsed_step = store.readStep(io, gpa, step_hash) catch |err| {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
            .code = "step_read_failed",
            .message = "Failed to read step object.",
            .hint = @errorName(err),
            .hash = hex[0..],
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer parsed_step.deinit();

    var current_tree = readTreeFromHex(io, gpa, &store, parsed_step.value.tree, usage.name, &stdout);
    defer current_tree.deinit();

    var parent_tree: ?std.json.Parsed(store_mod.Tree) = null;
    defer if (parent_tree) |*parsed| parsed.deinit();

    const old_entries = if (parsed_step.value.parent) |parent_hash_hex| blk: {
        const parent_hash = store_mod.Hash.fromHex(parent_hash_hex) catch {
            try status.writeDiagnostic(&stdout, .human, usage.name, .{
                .code = "invalid_parent_hash",
                .message = "Step parent hash is invalid.",
                .hash = parent_hash_hex,
            });
            try stdout.flush();
            std.process.exit(1);
        };
        var parsed_parent = store.readStep(io, gpa, parent_hash) catch |err| {
            try status.writeDiagnostic(&stdout, .human, usage.name, .{
                .code = "parent_step_read_failed",
                .message = "Failed to read parent step object.",
                .hint = @errorName(err),
                .hash = parent_hash_hex,
            });
            try stdout.flush();
            std.process.exit(1);
        };
        const tree = readTreeFromHex(io, gpa, &store, parsed_parent.value.tree, usage.name, &stdout);
        parsed_parent.deinit();
        parent_tree = tree;
        break :blk parent_tree.?.value.entries;
    } else &.{};

    var comparison = inspect_mod.compareTreeEntries(gpa, old_entries, current_tree.value.entries) catch |err| {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
            .code = "tree_compare_failed",
            .message = "Failed to compare step trees.",
            .hint = @errorName(err),
            .hash = hex[0..],
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer comparison.deinit(gpa);

    try writeHuman(
        io,
        gpa,
        &stdout,
        &store,
        options,
        comparison.entries,
        use_redaction,
        loaded_config.value.privacy.custom_literals,
    );
    try stdout.flush();
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
            try stdout.interface.print("Path {s} was not captured in this step or its parent.\n", .{path});
            return;
        }
    }
    if (!rendered_any) {
        try stdout.interface.writeAll("No file changes captured in this step.\n");
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
    command_name: []const u8,
    stdout: *std.Io.File.Writer,
) std.json.Parsed(store_mod.Tree) {
    const tree_hash = store_mod.Hash.fromHex(tree_hash_hex) catch {
        status.writeDiagnostic(stdout, .human, command_name, .{
            .code = "invalid_tree_hash",
            .message = "Step tree hash is invalid.",
            .hash = tree_hash_hex,
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
    return store.readTree(io, gpa, tree_hash) catch |err| {
        status.writeDiagnostic(stdout, .human, command_name, .{
            .code = "tree_read_failed",
            .message = "Failed to read step tree.",
            .hint = @errorName(err),
            .hash = tree_hash_hex,
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
                try invalidArgument(stdout, "Only one path may follow `--`.");
                return error.InvalidArgument;
            }
            options.path = arg;
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            path_mode = true;
        } else if (std.mem.eql(u8, arg, "--redacted")) {
            options.redaction_mode = .redacted;
        } else if (std.mem.eql(u8, arg, "--full")) {
            options.redaction_mode = .full;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (options.hash_prefix == null) {
            options.hash_prefix = arg;
        } else {
            try invalidArgument(stdout, "Unexpected argument.");
            return error.InvalidArgument;
        }
    }

    if (path_mode and options.path == null) {
        try invalidArgument(stdout, "`--` must be followed by a captured path.");
        return error.InvalidArgument;
    }
    return options;
}

fn invalidArgument(stdout: *std.Io.File.Writer, message: []const u8) !void {
    try status.writeDiagnostic(stdout, .human, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    try stdout.interface.writeAll("\n");
    try help_mod.renderUsage(stdout, usage);
    try stdout.flush();
}

fn shouldUseRedaction(mode: RedactionMode, redacted_by_default: bool) bool {
    return switch (mode) {
        .auto => redacted_by_default,
        .redacted => true,
        .full => false,
    };
}

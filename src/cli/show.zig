const std = @import("std");
const config_mod = @import("../store/config.zig");
const inspect_mod = @import("../store/inspect.zig");
const object_mod = @import("../store/object.zig");
const redact_mod = @import("../privacy/redact.zig");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");

pub const usage = specs.show_usage;

const RedactionMode = enum {
    auto,
    redacted,
    full,
};

const ShowOptions = struct {
    format: output_mod.Format = .human,
    hash_prefix: ?[:0]const u8 = null,
    show_files: bool = false,
    show_stat: bool = false,
    redaction_mode: RedactionMode = .auto,
};

const StatPath = struct {
    kind: inspect_mod.ChangeKind,
    path: []const u8,
};

const StatSummary = struct {
    counts: inspect_mod.ChangeCounts,
    changed_paths: []StatPath,

    fn deinit(self: *StatSummary, gpa: std.mem.Allocator) void {
        gpa.free(self.changed_paths);
        self.* = undefined;
    }
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    const prefix = options.hash_prefix orelse {
        if (options.format == .json) {
            try status.writeDiagnostic(&stdout, .json, usage.name, .{
                .code = "missing_hash",
                .message = "A hash prefix is required.",
            });
        } else {
            try help_mod.renderUsage(&stdout, usage);
        }
        try stdout.flush();
        std.process.exit(1);
    };

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);
    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa);
    defer loaded_config.deinit();
    const use_redaction = shouldUseRedaction(options.redaction_mode, loaded_config.value.privacy.display.redacted_by_default);

    const resolution = store.resolvePrefix(io, gpa, prefix) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "object_lookup_failed",
            .message = "Failed to resolve object prefix.",
            .hint = @errorName(err),
            .hash = prefix,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    const h = switch (resolution) {
        .not_found => {
            try status.writeDiagnostic(&stdout, options.format, usage.name, .{
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
            try status.writeDiagnostic(&stdout, options.format, usage.name, .{
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
    const hex = h.toHex();

    var parsed = store.readStep(io, gpa, h) catch |err| {
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
                .hash = hex[0..],
            },
            else => .{
                .code = "object_read_failed",
                .message = "Failed to read step object.",
                .hint = @errorName(err),
                .hash = hex[0..],
            },
        };
        try status.writeDiagnostic(&stdout, options.format, usage.name, diagnostic);
        try stdout.flush();
        std.process.exit(1);
    };
    defer parsed.deinit();

    var current_tree: ?std.json.Parsed(store_mod.Tree) = null;
    defer if (current_tree) |*parsed_tree| parsed_tree.deinit();

    var stat_summary: ?StatSummary = null;
    defer if (stat_summary) |*summary| summary.deinit(gpa);

    if (options.show_files or options.show_stat) {
        current_tree = readTreeFromHex(io, gpa, &store, parsed.value.tree, usage.name, &stdout);
    }
    if (options.show_stat) {
        var parent_tree: ?std.json.Parsed(store_mod.Tree) = null;
        defer if (parent_tree) |*parsed_tree| parsed_tree.deinit();
        const old_entries = if (parsed.value.parent) |parent_hash_hex| blk: {
            const parent_hash = store_mod.Hash.fromHex(parent_hash_hex) catch {
                try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                    .code = "invalid_parent_hash",
                    .message = "Step parent hash is invalid.",
                    .hash = parent_hash_hex,
                });
                try stdout.flush();
                std.process.exit(1);
            };
            var parent_step = store.readStep(io, gpa, parent_hash) catch |err| {
                try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                    .code = "parent_step_read_failed",
                    .message = "Failed to read parent step.",
                    .hint = @errorName(err),
                    .hash = parent_hash_hex,
                });
                try stdout.flush();
                std.process.exit(1);
            };
            defer parent_step.deinit();
            parent_tree = readTreeFromHex(io, gpa, &store, parent_step.value.tree, usage.name, &stdout);
            break :blk parent_tree.?.value.entries;
        } else &.{};

        var comparison = inspect_mod.compareTreeEntries(gpa, old_entries, current_tree.?.value.entries) catch |err| {
            try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                .code = "tree_compare_failed",
                .message = "Failed to compare step trees.",
                .hint = @errorName(err),
                .hash = hex[0..],
            });
            try stdout.flush();
            std.process.exit(1);
        };
        defer comparison.deinit(gpa);
        stat_summary = try buildStatSummary(gpa, comparison);
    }

    switch (options.format) {
        .human => try writeHuman(
            &stdout,
            gpa,
            hex[0..],
            parsed.value,
            use_redaction,
            loaded_config.value.privacy.custom_literals,
            if (current_tree) |tree| tree.value.entries else null,
            stat_summary,
        ),
        .json => {
            if (!use_redaction) {
                try output_mod.writeEnvelope(&stdout, usage.name, .{
                    .hash = hex[0..],
                    .step = parsed.value,
                    .files = if (current_tree) |tree| tree.value.entries else null,
                    .stat = stat_summary,
                });
            } else {
                const step = try redactStep(gpa, parsed.value, loaded_config.value.privacy.custom_literals);
                try output_mod.writeEnvelope(&stdout, usage.name, .{
                    .hash = hex[0..],
                    .step = step,
                    .files = if (current_tree) |tree| tree.value.entries else null,
                    .stat = stat_summary,
                });
            }
        },
    }
    try stdout.flush();
}

fn writeHuman(
    stdout: *std.Io.File.Writer,
    gpa: std.mem.Allocator,
    hex: []const u8,
    step: anytype,
    use_redaction: bool,
    custom_literals: []const []const u8,
    files: ?[]const store_mod.TreeEntry,
    stat_summary: ?StatSummary,
) !void {
    var ts_buf: [32]u8 = undefined;
    const ts = status.formatTimestamp(step.timestamp, &ts_buf);

    try stdout.interface.print("step      {s}\n", .{hex});
    try stdout.interface.print("origin    {s}\n", .{step.origin});
    try stdout.interface.print("session   {s}\n", .{step.session_id});
    try stdout.interface.print("turn      {s}\n", .{step.turn_id});
    try stdout.interface.print("parent    {s}\n", .{step.parent orelse "(none)"});
    try stdout.interface.print("tree      {s}\n", .{step.tree});
    try stdout.interface.print("timestamp {s}\n", .{ts});

    if (step.messages.len > 0) {
        try stdout.interface.writeAll("\nmessages:\n");
        for (step.messages, 0..) |msg, i| {
            const rendered = if (use_redaction) try redact_mod.redactAlloc(gpa, msg.content, .{
                .custom_literals = custom_literals,
            }) else msg.content;
            defer if (use_redaction) gpa.free(rendered);
            const preview_len = @min(80, rendered.len);
            const preview = rendered[0..preview_len];
            const ellipsis: []const u8 = if (rendered.len > 80) "…" else "";
            try stdout.interface.print("  [{d}] {s}: {s}{s}\n", .{ i, msg.role, preview, ellipsis });
        }
    }

    if (step.tool_calls.len > 0) {
        try stdout.interface.writeAll("\ntool_calls:\n");
        for (step.tool_calls, 0..) |tc, i| {
            try stdout.interface.print("  [{d}] {s}\n", .{ i, tc.tool_name });
        }
    }

    if (files) |entries| {
        try stdout.interface.writeAll("\nfiles:\n");
        if (entries.len == 0) {
            try stdout.interface.writeAll("  (none)\n");
        } else {
            for (entries) |entry| {
                try stdout.interface.print("  {s} ({d} B)\n", .{ entry.path, entry.size });
            }
        }
    }

    if (stat_summary) |summary| {
        try stdout.interface.writeAll("\nstat:\n");
        try stdout.interface.print("  added     {d}\n", .{summary.counts.added});
        try stdout.interface.print("  modified  {d}\n", .{summary.counts.modified});
        try stdout.interface.print("  deleted   {d}\n", .{summary.counts.deleted});
        try stdout.interface.print("  unchanged {d}\n", .{summary.counts.unchanged});
        if (summary.changed_paths.len == 0) {
            try stdout.interface.writeAll("  changes   (none)\n");
        } else {
            try stdout.interface.writeAll("  changes:\n");
            for (summary.changed_paths) |path| {
                try stdout.interface.print("    {s:<8} {s}\n", .{ @tagName(path.kind), path.path });
            }
        }
    }
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !ShowOptions {
    var options: ShowOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--files")) {
            options.show_files = true;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            options.show_stat = true;
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
            try status.writeDiagnostic(stdout, options.format, usage.name, .{
                .code = "invalid_argument",
                .message = "Unexpected argument.",
                .hint = arg,
            });
            if (options.format == .human) {
                try stdout.interface.writeAll("\n");
                try help_mod.renderUsage(stdout, usage);
            }
            try stdout.flush();
            std.process.exit(1);
        }
    }
    return options;
}

fn shouldUseRedaction(mode: RedactionMode, redacted_by_default: bool) bool {
    return switch (mode) {
        .auto => redacted_by_default,
        .redacted => true,
        .full => false,
    };
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

fn buildStatSummary(gpa: std.mem.Allocator, comparison: inspect_mod.TreeComparison) !StatSummary {
    var changed_paths: std.ArrayList(StatPath) = .empty;
    errdefer changed_paths.deinit(gpa);
    for (comparison.entries) |entry| {
        if (entry.kind == .unchanged) continue;
        try changed_paths.append(gpa, .{
            .kind = entry.kind,
            .path = entry.path,
        });
    }
    return .{
        .counts = comparison.counts,
        .changed_paths = try changed_paths.toOwnedSlice(gpa),
    };
}

fn redactStep(
    gpa: std.mem.Allocator,
    step: object_mod.Step,
    custom_literals: []const []const u8,
) !object_mod.Step {
    const messages = try gpa.alloc(object_mod.StepMessage, step.messages.len);
    errdefer gpa.free(messages);
    for (step.messages, 0..) |message, i| {
        messages[i] = .{
            .role = message.role,
            .content = try redact_mod.redactAlloc(gpa, message.content, .{
                .custom_literals = custom_literals,
            }),
        };
    }

    const tool_calls = try gpa.alloc(object_mod.StepToolCall, step.tool_calls.len);
    errdefer {
        for (messages) |message| gpa.free(@constCast(message.content));
        gpa.free(messages);
        gpa.free(tool_calls);
    }
    for (step.tool_calls, 0..) |tool_call, i| {
        tool_calls[i] = .{
            .tool_name = tool_call.tool_name,
            .args = try redact_mod.redactAlloc(gpa, tool_call.args, .{
                .custom_literals = custom_literals,
            }),
            .result = if (tool_call.result) |result| try redact_mod.redactAlloc(gpa, result, .{
                .custom_literals = custom_literals,
            }) else null,
        };
    }

    return .{
        .type = step.type,
        .parent = step.parent,
        .tree = step.tree,
        .session_id = step.session_id,
        .origin = step.origin,
        .turn_id = step.turn_id,
        .causes = step.causes,
        .timestamp = step.timestamp,
        .messages = messages,
        .tool_calls = tool_calls,
    };
}

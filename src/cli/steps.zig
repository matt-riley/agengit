const std = @import("std");
const inspect_mod = @import("../store/inspect.zig");
const session_arg = @import("session_arg.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const store_mod = @import("../store/store.zig");
const arg_parse = @import("arg_parse.zig");

pub const usage = specs.steps_usage;

const StepsOptions = struct {
    format: output_mod.Format = .human,
    session_arg: ?[:0]const u8 = null,
    include_step_objects: bool = false,
    include_diffs: bool = true,
};

const DiffInfo = struct {
    changes: []const JsonChange,
    counts: inspect_mod.ChangeCounts,

    fn deinit(self: *DiffInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.changes);
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
        else => return err,
    };

    // Steps command only supports JSON format.
    if (options.format != .json) {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "format_required",
            .message = "The steps command requires --json.",
        });
        try stdout.flush();
        return;
    }

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    const resolved = try session_arg.resolveExisting(gpa, &store, &stdout, options.format, usage.name, options.session_arg);
    defer resolved.deinit(gpa);

    const step_rows = try store.index.listSteps(gpa, resolved.origin, resolved.session_id);
    defer store_mod.freeStepRows(gpa, step_rows);

    // Build the step output array.
    // We keep parsed steps in a separate list for cleanup to avoid serializing std.json.Parsed
    // (which contains an arena allocator that Zig's JSON stringifier can't handle).
    var parsed_steps: std.ArrayList(std.json.Parsed(store_mod.Step)) = .empty;
    defer {
        for (parsed_steps.items) |*ps| ps.deinit();
        parsed_steps.deinit(gpa);
    }

    var step_outputs: std.ArrayList(struct {
        hash: []const u8,
        turn_id: []const u8,
        timestamp: i64,
        model: ?[]const u8 = null,
        outcome: ?[]const u8 = null,
        git_commit: ?[]const u8 = null,
        git_branch: ?[]const u8 = null,
        git_dirty: ?bool = null,
        step: ?store_mod.Step = null,
        diff: ?DiffInfo = null,
    }) = .empty;
    defer {
        for (step_outputs.items) |output_row| {
            if (output_row.diff) |diff| {
                var mutable_diff = diff;
                mutable_diff.deinit(gpa);
            }
        }
        step_outputs.deinit(gpa);
    }

    for (step_rows) |row| {
        var diff_info: ?DiffInfo = null;

        const step_hash = store_mod.Hash.fromHex(row.hash) catch {
            try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                .code = "invalid_hash",
                .message = "Invalid step hash in index.",
                .hash = row.hash,
            });
            try stdout.flush();
            std.process.exit(1);
        };

        var step_value: ?store_mod.Step = null;

        if (options.include_step_objects) {
            const parsed = store.readStep(io, gpa, step_hash) catch |err| {
                try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                    .code = "step_read_failed",
                    .message = "Failed to read step object.",
                    .hint = @errorName(err),
                    .hash = row.hash,
                });
                try stdout.flush();
                std.process.exit(1);
            };
            step_value = parsed.value;

            if (options.include_diffs) {
                // Read the step's tree for diff comparison.
                var current_tree = readTreeOrNull(io, gpa, &store, parsed.value.tree);
                defer if (current_tree) |*t| t.deinit();

                if (current_tree) |tree| {
                    // Read parent tree if available.
                    const old_entries: []const store_mod.TreeEntry = if (parsed.value.parent) |parent_hash_hex| blk: {
                        const parent_hash = store_mod.Hash.fromHex(parent_hash_hex) catch {
                            break :blk &.{};
                        };
                        var parent_step = store.readStep(io, gpa, parent_hash) catch {
                            break :blk &.{};
                        };
                        defer parent_step.deinit();
                        var parent_tree = readTreeOrNull(io, gpa, &store, parent_step.value.tree);
                        if (parent_tree) |*pt| {
                            defer pt.deinit();
                            break :blk pt.value.entries;
                        }
                        break :blk &.{};
                    } else &.{};

                    var comparison = inspect_mod.compareTreeEntries(gpa, old_entries, tree.value.entries) catch |err| {
                        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                            .code = "tree_compare_failed",
                            .message = "Failed to compare step trees.",
                            .hint = @errorName(err),
                            .hash = row.hash,
                        });
                        try stdout.flush();
                        std.process.exit(1);
                    };
                    defer comparison.deinit(gpa);

                    diff_info = DiffInfo{
                        .changes = try buildJsonChanges(gpa, comparison.entries),
                        .counts = comparison.counts,
                    };
                }
            }

            // Transfer parsed step to cleanup list
            try parsed_steps.append(gpa, parsed);
        }

        try step_outputs.append(gpa, .{
            .hash = row.hash,
            .turn_id = row.turn_id,
            .timestamp = row.timestamp,
            .model = row.model,
            .outcome = row.outcome,
            .git_commit = row.git_commit,
            .git_branch = row.git_branch,
            .git_dirty = row.git_dirty,
            .step = step_value,
            .diff = diff_info,
        });
    }

    try output_mod.writeEnvelope(&stdout, usage.name, .{
        .origin = resolved.origin,
        .session_id = resolved.session_id,
        .steps = step_outputs.items,
    });
    try stdout.flush();
}

fn readTreeOrNull(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    tree_hash_hex: []const u8,
) ?std.json.Parsed(store_mod.Tree) {
    const tree_hash = store_mod.Hash.fromHex(tree_hash_hex) catch return null;
    const result = store.readTree(io, gpa, tree_hash) catch return null;
    return result;
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

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !StepsOptions {
    var options: StepsOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--include-step-objects")) {
            options.include_step_objects = true;
        } else if (std.mem.eql(u8, arg, "--no-diffs")) {
            options.include_diffs = false;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (options.session_arg == null) {
            options.session_arg = arg;
        } else {
            arg_parse.invalidArg(stdout, options.format, usage, "Unexpected argument.") catch {};
            std.process.exit(1);
        }
    }
    return options;
}

// ── buildJsonChanges unit tests ───────────────────────────────────────────
// `buildJsonChanges` converts internal ComparedEntry slices into JSON-friendly
// JsonChange structs, filtering out unchanged entries. Each test verifies the
// filtering and field-mapping logic.

test "buildJsonChanges: empty input returns empty slice" {
    const gpa = std.testing.allocator;
    const entries: []const inspect_mod.ComparedEntry = &.{};
    const result = try buildJsonChanges(gpa, entries);
    defer gpa.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "buildJsonChanges: filters out unchanged entries" {
    const gpa = std.testing.allocator;
    const old_entry = inspect_mod.ComparedEntry{
        .kind = .unchanged,
        .path = "keep.zig",
        .old_entry = .{ .path = "keep.zig", .blob = "a" ** 64, .mode = "file", .size = 10 },
        .new_entry = .{ .path = "keep.zig", .blob = "a" ** 64, .mode = "file", .size = 10 },
    };
    const added_entry = inspect_mod.ComparedEntry{
        .kind = .added,
        .path = "new.zig",
        .new_entry = .{ .path = "new.zig", .blob = "b" ** 64, .mode = "file", .size = 20 },
    };
    const entries = [_]inspect_mod.ComparedEntry{ old_entry, added_entry };

    const result = try buildJsonChanges(gpa, &entries);
    defer gpa.free(result);

    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("added", result[0].kind);
    try std.testing.expectEqualStrings("new.zig", result[0].path);
    try std.testing.expect(result[0].old_blob == null);
    try std.testing.expectEqualStrings("b" ** 64, result[0].new_blob.?);
    try std.testing.expect(result[0].old_size == null);
    try std.testing.expectEqual(@as(u64, 20), result[0].new_size.?);
}

test "buildJsonChanges: maps added, modified, and deleted entries correctly" {
    const gpa = std.testing.allocator;
    const entries = [_]inspect_mod.ComparedEntry{
        .{
            .kind = .added,
            .path = "added.zig",
            .new_entry = .{ .path = "added.zig", .blob = "b" ** 64, .mode = "file", .size = 5 },
        },
        .{
            .kind = .modified,
            .path = "mod.zig",
            .old_entry = .{ .path = "mod.zig", .blob = "c" ** 64, .mode = "file", .size = 10 },
            .new_entry = .{ .path = "mod.zig", .blob = "d" ** 64, .mode = "file", .size = 15 },
        },
        .{
            .kind = .deleted,
            .path = "del.zig",
            .old_entry = .{ .path = "del.zig", .blob = "e" ** 64, .mode = "file", .size = 20 },
        },
    };

    const result = try buildJsonChanges(gpa, &entries);
    defer gpa.free(result);

    try std.testing.expectEqual(@as(usize, 3), result.len);

    // added
    try std.testing.expectEqualStrings("added", result[0].kind);
    try std.testing.expectEqualStrings("added.zig", result[0].path);
    try std.testing.expect(result[0].old_blob == null);
    try std.testing.expectEqualStrings("b" ** 64, result[0].new_blob.?);

    // modified
    try std.testing.expectEqualStrings("modified", result[1].kind);
    try std.testing.expectEqualStrings("mod.zig", result[1].path);
    try std.testing.expectEqualStrings("c" ** 64, result[1].old_blob.?);
    try std.testing.expectEqualStrings("d" ** 64, result[1].new_blob.?);
    try std.testing.expectEqual(@as(u64, 10), result[1].old_size.?);
    try std.testing.expectEqual(@as(u64, 15), result[1].new_size.?);

    // deleted
    try std.testing.expectEqualStrings("deleted", result[2].kind);
    try std.testing.expectEqualStrings("del.zig", result[2].path);
    try std.testing.expectEqualStrings("e" ** 64, result[2].old_blob.?);
    try std.testing.expect(result[2].new_blob == null);
    try std.testing.expectEqual(@as(u64, 20), result[2].old_size.?);
}

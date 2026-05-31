const std = @import("std");
const index_mod = @import("../store/index.zig");
const inspect_mod = @import("../store/inspect.zig");
const session_arg = @import("session_arg.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const store_mod = @import("../store/store.zig");

pub const usage = specs.stats_usage;

const default_tool_limit: usize = 20;
const default_path_limit: usize = 10;
const file_tally_step_cap: usize = 500;

const StatsOptions = struct {
    format: output_mod.Format = .human,
    session: ?[:0]const u8 = null,
};

const PathCount = struct {
    path: []const u8,
    count: usize,
};

const FileTally = struct {
    paths: []const PathCount,
    steps_considered: usize,
    truncated: bool,

    fn deinit(self: FileTally, gpa: std.mem.Allocator) void {
        for (self.paths) |row| gpa.free(row.path);
        gpa.free(self.paths);
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

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    var target: ?session_arg.Target = null;
    defer if (target) |resolved| resolved.deinit(gpa);
    if (options.session) |arg| {
        target = try session_arg.resolveExisting(gpa, &store, &stdout, options.format, usage.name, arg);
    }

    const stats_options: index_mod.StatsOptions = if (target) |resolved|
        .{ .origin = resolved.origin, .session_id = resolved.session_id }
    else
        .{};

    const summary = try store.index.statsSummary(stats_options);
    const session_rows = try store.index.listSessionStats(gpa, stats_options);
    defer index_mod.freeSessionStatsRows(gpa, session_rows);
    const tool_counts = try store.index.listToolCounts(gpa, stats_options, default_tool_limit);
    defer index_mod.freeToolCountRows(gpa, tool_counts);
    const tally = try buildFileTally(io, gpa, &store, stats_options, summary.step_count);
    defer tally.deinit(gpa);

    switch (options.format) {
        .human => try writeHuman(&stdout, summary, session_rows, tool_counts, tally, target),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .scope = if (target) |resolved| .{
                .origin = resolved.origin,
                .session_id = resolved.session_id,
            } else null,
            .summary = summary,
            .tool_calls = tool_counts,
            .sessions = session_rows,
            .most_changed_paths = tally.paths,
            .file_tally = .{
                .bounded = true,
                .step_cap = file_tally_step_cap,
                .steps_considered = tally.steps_considered,
                .truncated = tally.truncated,
            },
        }),
    }
    try stdout.flush();
}

fn writeHuman(
    stdout: *std.Io.File.Writer,
    summary: index_mod.StatsSummaryRow,
    sessions: []const index_mod.SessionStatsRow,
    tools: []const index_mod.ToolCountRow,
    tally: FileTally,
    target: ?session_arg.Target,
) !void {
    if (target) |resolved| {
        try stdout.interface.print("Scope: {s}/{s}\n", .{ resolved.origin, resolved.session_id });
    } else {
        try stdout.interface.writeAll("Scope: repository\n");
    }
    try stdout.interface.print("Sessions: {d}\n", .{summary.session_count});
    try stdout.interface.print("Steps: {d}\n", .{summary.step_count});
    try stdout.interface.print("Turns: {d}\n", .{summary.turn_count});
    try stdout.interface.print("Capture span: ", .{});
    try writeSpan(stdout, summary.first_timestamp, summary.last_timestamp);
    try stdout.interface.writeAll("\n");

    try stdout.interface.writeAll("\nTool calls:\n");
    if (tools.len == 0) {
        try stdout.interface.writeAll("  (none)\n");
    } else {
        for (tools) |row| {
            try stdout.interface.print("  {s}: {d}\n", .{ row.tool_name, row.count });
        }
    }

    try stdout.interface.writeAll("\nSessions:\n");
    if (sessions.len == 0) {
        try stdout.interface.writeAll("  (none)\n");
    } else {
        for (sessions) |row| {
            try stdout.interface.print("  {s}/{s}: {d} steps, {d} turns, ", .{
                row.origin,
                row.session_id,
                row.step_count,
                row.turn_count,
            });
            try writeSpan(stdout, row.first_timestamp, row.last_timestamp);
            try stdout.interface.writeAll("\n");
        }
    }

    try stdout.interface.print("\nMost changed paths (top {d}, {d} steps considered", .{
        default_path_limit,
        tally.steps_considered,
    });
    if (tally.truncated) {
        try stdout.interface.print(", capped at {d}", .{file_tally_step_cap});
    }
    try stdout.interface.writeAll("):\n");
    if (tally.paths.len == 0) {
        try stdout.interface.writeAll("  (none)\n");
    } else {
        for (tally.paths) |row| {
            try stdout.interface.print("  {s}: {d}\n", .{ row.path, row.count });
        }
    }
}

fn writeSpan(stdout: *std.Io.File.Writer, first: ?i64, last: ?i64) !void {
    if (first == null or last == null) {
        try stdout.interface.writeAll("(none)");
        return;
    }
    var first_buf: [32]u8 = undefined;
    var last_buf: [32]u8 = undefined;
    try stdout.interface.print("{s} -> {s}", .{
        status.formatTimestamp(first.?, &first_buf),
        status.formatTimestamp(last.?, &last_buf),
    });
}

fn buildFileTally(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    options: index_mod.StatsOptions,
    total_steps: i64,
) !FileTally {
    const steps = try store.index.listStatsSteps(gpa, options, file_tally_step_cap);
    defer store_mod.freeStepRows(gpa, steps);

    var counts = std.StringHashMap(usize).init(gpa);
    defer {
        var it = counts.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        counts.deinit();
    }

    for (steps) |step| {
        var current_tree = try readTreeOrExit(io, gpa, store, step.tree_hash);
        defer current_tree.deinit();

        var parent_step: ?std.json.Parsed(store_mod.Step) = null;
        defer if (parent_step) |*parsed| parsed.deinit();
        var parent_tree: ?std.json.Parsed(store_mod.Tree) = null;
        defer if (parent_tree) |*parsed| parsed.deinit();

        const old_entries: []const store_mod.TreeEntry = if (step.parent_hash) |parent_hash_hex| blk: {
            const parent_hash = try store_mod.Hash.fromHex(parent_hash_hex);
            parent_step = try store.readStep(io, gpa, parent_hash);
            parent_tree = try readTreeOrExit(io, gpa, store, parent_step.?.value.tree);
            break :blk parent_tree.?.value.entries;
        } else &.{};

        var comparison = try inspect_mod.compareTreeEntries(gpa, old_entries, current_tree.value.entries);
        defer comparison.deinit(gpa);
        for (comparison.entries) |entry| {
            if (entry.kind == .unchanged) continue;
            if (counts.getPtr(entry.path)) |count| {
                count.* += 1;
            } else {
                try counts.putNoClobber(try gpa.dupe(u8, entry.path), 1);
            }
        }
    }

    var rows: std.ArrayList(PathCount) = .empty;
    errdefer {
        for (rows.items) |row| gpa.free(row.path);
        rows.deinit(gpa);
    }
    var it = counts.iterator();
    while (it.next()) |entry| {
        try rows.append(gpa, .{
            .path = try gpa.dupe(u8, entry.key_ptr.*),
            .count = entry.value_ptr.*,
        });
    }
    std.mem.sort(PathCount, rows.items, {}, lessPathCount);
    if (rows.items.len > default_path_limit) {
        for (rows.items[default_path_limit..]) |row| gpa.free(row.path);
        rows.shrinkRetainingCapacity(default_path_limit);
    }

    return .{
        .paths = try rows.toOwnedSlice(gpa),
        .steps_considered = steps.len,
        .truncated = total_steps > @as(i64, @intCast(steps.len)),
    };
}

fn lessPathCount(_: void, a: PathCount, b: PathCount) bool {
    if (a.count != b.count) return a.count > b.count;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn readTreeOrExit(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    tree_hash_hex: []const u8,
) !std.json.Parsed(store_mod.Tree) {
    const tree_hash = try store_mod.Hash.fromHex(tree_hash_hex);
    return store.readTree(io, gpa, tree_hash);
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !StatsOptions {
    var options: StatsOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--session")) {
            options.session = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--session requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            try invalidArgument(stdout, options.format, "Unexpected argument.");
            return error.InvalidArgument;
        }
    }
    return options;
}

fn invalidArgument(stdout: *std.Io.File.Writer, format: output_mod.Format, message: []const u8) !void {
    try status.writeDiagnostic(stdout, format, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    if (format == .human) {
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(stdout, usage);
    }
    try stdout.flush();
}

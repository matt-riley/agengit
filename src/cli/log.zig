const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");

pub const usage = help_mod.UsageSpec{
    .name = "log",
    .synopsis = "[OPTIONS] [SESSION_ID]",
    .description = "Show step history for a session.",
    .options = &.{
        .{ .flag = "-h, --help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show most recent session steps", .command = "" },
        .{ .description = "show steps for a specific session", .command = "session-abc123" },
    },
};

// Phase 6 implementation: show step history for a session.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    var store = (try status.openStoreOrDie(io, gpa, &stdout)) orelse return;
    defer store.deinit(io);

    // Parse --help and target session ID
    var help_requested = false;
    var session_arg: ?[:0]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help_requested = true;
            break;
        } else if (session_arg == null) {
            session_arg = arg;
        }
    }

    if (help_requested) {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    }

    const resolved = try resolveSessionArg(io, gpa, &store, session_arg, &stdout) orelse return;
    defer {
        gpa.free(resolved.origin);
        gpa.free(resolved.session_id);
    }

    const steps = try store.index.listSteps(gpa, resolved.origin, resolved.session_id);
    defer store_mod.freeStepRows(gpa, steps);

    if (steps.len == 0) {
        try stdout.interface.print("No steps recorded for {s}/{s}\n", .{
            resolved.origin, resolved.session_id,
        });
        try stdout.flush();
        return;
    }

    try stdout.interface.print("session {s}/{s}\n\n", .{ resolved.origin, resolved.session_id });

    var ts_buf: [32]u8 = undefined;
    var i = steps.len;
    while (i > 0) {
        i -= 1;
        const step = steps[i];
        const ts = status.formatTimestamp(step.timestamp, &ts_buf);
        try stdout.interface.print("step {s}  turn {s}  {s}\n", .{
            step.hash[0..@min(16, step.hash.len)],
            step.turn_id,
            ts,
        });
    }
    try stdout.flush();
}

const SessionTarget = struct {
    origin: []const u8,
    session_id: []const u8,
};

fn resolveSessionArg(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    arg: ?[:0]const u8,
    stdout: anytype,
) !?SessionTarget {
    _ = io;
    if (arg) |a| {
        if (std.mem.indexOfScalar(u8, a, '/')) |sep| {
            return .{
                .origin = try gpa.dupe(u8, a[0..sep]),
                .session_id = try gpa.dupe(u8, a[sep + 1 ..]),
            };
        }
        // Search by session_id across all origins
        const row = try store.index.db.row(
            "select origin, session_id from sessions where session_id=? order by updated_at desc limit 1",
            .{a},
        ) orelse {
            try stdout.interface.print("error: session '{s}' not found\n", .{a});
            try stdout.flush();
            return null;
        };
        defer row.deinit();
        return .{
            .origin = try gpa.dupe(u8, row.get([]const u8, 0)),
            .session_id = try gpa.dupe(u8, row.get([]const u8, 1)),
        };
    } else {
        const sess = try store.index.mostRecentSession(gpa) orelse {
            try stdout.interface.writeAll("No sessions recorded yet.\n");
            try stdout.flush();
            return null;
        };
        // Transfer origin/session_id ownership; free head_hash which we don't need.
        if (sess.head_hash) |hh| gpa.free(hh);
        return .{ .origin = sess.origin, .session_id = sess.session_id };
    }
}

const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");

pub const usage = help_mod.UsageSpec{
    .name = "sessions",
    .synopsis = "[OPTIONS]",
    .description = "List recorded agent sessions from the index.",
    .options = &.{
        .{ .flag = "-h, --help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "list all sessions", .command = "" },
    },
};

// Phase 6 implementation: list recorded agent sessions from the index.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    // Parse --help / -h
    var help_requested = false;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help_requested = true;
            break;
        }
    }

    if (help_requested) {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    }

    var store = (try status.openStoreOrDie(io, gpa, &stdout)) orelse return;
    defer store.deinit(io);

    const sessions = try store.index.listSessions(gpa);
    defer store_mod.freeSessionRows(gpa, sessions);

    if (sessions.len == 0) {
        try stdout.interface.writeAll("No sessions recorded yet. Run `agit init` and record some activity.\n");
        try stdout.flush();
        return;
    }

    // Column widths: origin 30, session_id 24, head 8, updated 19
    try stdout.interface.writeAll("ORIGIN                         SESSION                  HEAD      UPDATED\n");
    try stdout.interface.writeAll("────────────────────────────── ──────────────────────── ──────── ───────────────────\n");

    var ts_buf: [32]u8 = undefined;
    for (sessions) |s| {
        const head = if (s.head_hash) |h| h[0..@min(8, h.len)] else "────────";
        const updated = status.formatTimestamp(s.updated_at * 1000, &ts_buf);
        try stdout.interface.print("{s:<30} {s:<24} {s:<8} {s}\n", .{
            s.origin[0..@min(30, s.origin.len)],
            s.session_id[0..@min(24, s.session_id.len)],
            head,
            updated,
        });
    }
    try stdout.flush();
}

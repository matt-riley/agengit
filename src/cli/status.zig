const std = @import("std");
const store_mod = @import("../store/store.zig");

/// Format a millisecond-precision Unix timestamp as "YYYY-MM-DD HH:MM:SS".
pub fn formatTimestamp(ms: i64, buf: *[32]u8) []const u8 {
    if (ms <= 0) return "(unknown)";
    const secs: u64 = @intCast(@max(0, @divTrunc(ms, 1000)));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const eday = es.getEpochDay();
    const yd = eday.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

/// Open the store, printing a friendly error on failure.
/// Returns null if the store could not be opened.
pub fn openStoreOrDie(
    io: std.Io,
    gpa: std.mem.Allocator,
    writer: anytype,
) !?store_mod.Store {
    return store_mod.Store.findAndOpen(io, std.Io.Dir.cwd(), gpa) catch |err| {
        switch (err) {
            error.StoreNotFound => try writer.interface.writeAll(
                "Not an agit repository (no .agit/ directory found here or in any parent).\n",
            ),
            else => try writer.interface.print(
                "error opening store: {s}\n",
                .{@errorName(err)},
            ),
        }
        try writer.flush();
        return null;
    };
}

// Phase 6 implementation: show current repository agit state.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = iter;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    var store = (try openStoreOrDie(io, gpa, &stdout)) orelse return;
    defer store.deinit(io);

    const n_sessions = try store.index.countSessions();
    const n_steps = try store.index.countSteps();

    try stdout.interface.print("Sessions: {d}\n", .{n_sessions});
    try stdout.interface.print("Steps:    {d}\n", .{n_steps});
    try stdout.flush();
}

test "formatTimestamp epoch zero" {
    var buf: [32]u8 = undefined;
    const s = formatTimestamp(0, &buf);
    try std.testing.expectEqualStrings("(unknown)", s);
}

test "formatTimestamp known date" {
    // 2024-01-01 00:00:00 UTC = 1704067200 seconds = 1704067200000 ms
    var buf: [32]u8 = undefined;
    const s = formatTimestamp(1704067200000, &buf);
    try std.testing.expectEqualStrings("2024-01-01 00:00:00", s);
}

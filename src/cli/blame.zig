const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");

// Phase 6 implementation: show per-line step attribution for a file path.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = gpa;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    _ = iter.next(); // consume any path argument

    // Blame recording is not yet implemented in the capture engine.
    // Blame maps will be written in a future phase when the recorder
    // calls store.writeBlame() during recordAssistantAndFinalize.
    try stdout.interface.writeAll("agit blame: blame recording is not yet available.\n");
    try stdout.interface.writeAll("Run `agit reindex` after upgrading to a version with blame support.\n");
    try stdout.flush();
}

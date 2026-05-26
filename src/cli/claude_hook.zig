const std = @import("std");
const runner = @import("../hook/runner.zig");
const claude = @import("../hook/adapters/claude.zig");

/// Entry point. Always exits cleanly — errors are logged to stderr.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    try runner.run(io, gpa, iter, claude.hook_adapter);
}

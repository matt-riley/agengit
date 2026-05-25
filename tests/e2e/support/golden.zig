const std = @import("std");
const harness = @import("harness.zig");

pub fn assertGolden(sandbox: *harness.Sandbox, rel_path: []const u8, got: []const u8) !void {
    const gpa = sandbox.gpa;
    const io = sandbox.io;

    const repo_root = deriveRepoRoot(sandbox.agit_bin) orelse return error.FileNotFound;
    const golden_abs = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ repo_root, rel_path });
    defer gpa.free(golden_abs);

    const should_update = envFlagEnabled(gpa, io, "AGIT_UPDATE_GOLDEN");

    if (should_update) {
        if (std.mem.lastIndexOfScalar(u8, golden_abs, '/')) |idx| {
            try std.Io.Dir.cwd().createDirPath(io, golden_abs[0..idx]);
        }
        var file = try std.Io.Dir.cwd().createFile(io, golden_abs, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, got);
        return;
    }

    const want = try std.Io.Dir.cwd().readFileAlloc(io, golden_abs, gpa, .unlimited);
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, got);
}

fn envFlagEnabled(gpa: std.mem.Allocator, io: std.Io, name: []const u8) bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/printenv", name },
    }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return false;
    const trimmed = std.mem.trim(u8, res.stdout, " \r\n");
    return std.mem.eql(u8, trimmed, "1");
}

fn deriveRepoRoot(agit_bin: []const u8) ?[]const u8 {
    const bin_dir = std.fs.path.dirname(agit_bin) orelse return null;
    const zig_out_dir = std.fs.path.dirname(bin_dir) orelse return null;
    return std.fs.path.dirname(zig_out_dir);
}

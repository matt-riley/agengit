const std = @import("std");

pub fn hasExecutableInPath(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    name: []const u8,
) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfScalar(u8, name, '/')) |_| return false;
    if (std.mem.indexOfScalar(u8, name, '\\')) |_| return false;

    const raw_path = environ.getPosix("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, raw_path, std.fs.path.delimiter);
    while (it.next()) |segment_raw| {
        const segment = if (segment_raw.len == 0) "." else segment_raw;
        const candidate = std.fs.path.join(gpa, &.{ segment, name }) catch return false;
        defer gpa.free(candidate);

        const file = std.Io.Dir.cwd().openFile(io, candidate, .{}) catch continue;
        file.close(io);
        return true;
    }
    return false;
}

test "hasExecutableInPath resolves executables from PATH segments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try tmp.dir.createDirPath(io, "bin");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &path_buf);
    const bin_path = try std.fmt.allocPrint(gpa, "{s}/bin", .{path_buf[0..root_len]});
    defer gpa.free(bin_path);

    var file = try tmp.dir.createFile(io, "bin/codex-test-bin", .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "echo ok\n");

    const path_env_raw = try std.fmt.allocPrint(gpa, "PATH={s}", .{bin_path});
    defer gpa.free(path_env_raw);
    const path_env = try gpa.dupeZ(u8, path_env_raw);
    defer gpa.free(path_env);
    const env_entries = [_:null]?[*:0]const u8{path_env.ptr};
    const environ = std.process.Environ{ .block = .{ .slice = &env_entries } };

    try std.testing.expect(hasExecutableInPath(io, gpa, environ, "codex-test-bin"));
    try std.testing.expect(!hasExecutableInPath(io, gpa, environ, "does-not-exist"));
}

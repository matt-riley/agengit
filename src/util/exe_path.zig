const std = @import("std");
const builtin = @import("builtin");

/// Returns the absolute path of the current executable into `out_buffer`.
/// The returned slice is a subslice of `out_buffer`.
/// Used when writing hook configurations that must contain the absolute agit binary path.
pub fn get(io: std.Io, out_buffer: []u8) ![]const u8 {
    const n = try std.process.executablePath(io, out_buffer);
    return out_buffer[0..n];
}

/// Allocates and returns the absolute path of the current executable.
/// Caller owns the returned slice and must free it with `gpa.free`.
pub fn getAlloc(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    // executablePathAlloc returns a sentinel-terminated [:0]u8 (len+1 bytes).
    // Callers treat the result as a plain []u8 and free by slice length, which
    // would under-free by one byte; return a non-sentinel dupe so the allocated
    // size matches the freed size.
    const z = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(z);
    return try gpa.dupe(u8, z);
}

/// Returns a stable absolute path suitable for long-lived hook configs.
///
/// Package managers such as Homebrew often execute through a stable symlink
/// while `executablePathAlloc` reports the resolved versioned store path. Prefer
/// a PATH entry named `agit` when it resolves to the same executable; fall back
/// to the current executable path otherwise.
pub fn getHookBinaryAlloc(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    const exe = try getAlloc(io, gpa);
    errdefer gpa.free(exe);

    if (try findMatchingPathEntryAlloc(io, gpa, environ, exe, "agit")) |path_entry| {
        gpa.free(exe);
        return path_entry;
    }

    return exe;
}

fn findMatchingPathEntryAlloc(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    exe: []const u8,
    name: []const u8,
) !?[]u8 {
    const raw_path = environ.getPosix("PATH") orelse return null;

    var exe_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_real_len = std.Io.Dir.realPathFileAbsolute(io, exe, &exe_real_buf) catch return null;
    const exe_real = exe_real_buf[0..exe_real_len];

    var it = std.mem.splitScalar(u8, raw_path, std.fs.path.delimiter);
    while (it.next()) |segment_raw| {
        const segment = if (segment_raw.len == 0) "." else segment_raw;
        const candidate = try std.fs.path.join(gpa, &.{ segment, name });
        defer gpa.free(candidate);

        var candidate_real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate_real_len = std.Io.Dir.realPathFileAbsolute(io, candidate, &candidate_real_buf) catch continue;
        const candidate_real = candidate_real_buf[0..candidate_real_len];
        if (!std.mem.eql(u8, candidate_real, exe_real)) continue;

        if (std.fs.path.isAbsolute(candidate)) {
            return try gpa.dupe(u8, candidate);
        }
        return try std.Io.Dir.realPathFileAbsoluteAlloc(io, candidate, gpa);
    }

    return null;
}

test "exe path is non-empty and absolute" {
    // In test builds, executablePath should return a non-empty absolute path.
    // We only verify basic structural properties here.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // Pass a dummy Io — tests run with a real process, so the real io is available.
    // The test harness provides std.testing.io; use it via std.Io directly.
    const path = get(std.testing.io, &buf) catch return; // skip if OS doesn't support it
    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.fs.path.isAbsolute(path));
}

test "getHookBinaryAlloc prefers stable PATH symlink to same executable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try tmp.dir.createDirPath(io, "Cellar/agit/1.2.3/bin");
    try tmp.dir.createDirPath(io, "bin");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const versioned = try std.fmt.allocPrint(gpa, "{s}/Cellar/agit/1.2.3/bin/agit", .{root});
    defer gpa.free(versioned);
    const stable = try std.fmt.allocPrint(gpa, "{s}/bin/agit", .{root});
    defer gpa.free(stable);
    const bin_dir = try std.fmt.allocPrint(gpa, "{s}/bin", .{root});
    defer gpa.free(bin_dir);

    {
        var file = try tmp.dir.createFile(io, "Cellar/agit/1.2.3/bin/agit", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "test binary\n");
    }
    try tmp.dir.symLink(io, "../Cellar/agit/1.2.3/bin/agit", "bin/agit", .{});

    const path_env_raw = try std.fmt.allocPrint(gpa, "PATH={s}", .{bin_dir});
    defer gpa.free(path_env_raw);
    const path_env = try gpa.dupeZ(u8, path_env_raw);
    defer gpa.free(path_env);
    const env_entries = [_:null]?[*:0]const u8{path_env.ptr};
    const environ = std.process.Environ{ .block = .{ .slice = &env_entries } };

    const resolved = try findMatchingPathEntryAlloc(io, gpa, environ, versioned, "agit") orelse return error.MissingPathEntry;
    defer gpa.free(resolved);

    try std.testing.expectEqualStrings(stable, resolved);
}

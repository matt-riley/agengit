const std = @import("std");

/// Returns the absolute path of the current executable into `out_buffer`.
/// The returned slice is a subslice of `out_buffer`.
/// Used when writing hook configurations that must contain the absolute agit binary path.
pub fn get(io: std.Io, out_buffer: []u8) ![]const u8 {
    const n = try std.process.executablePath(io, out_buffer);
    return out_buffer[0..n];
}

/// Allocates and returns the absolute path of the current executable.
/// Caller owns the returned slice and must free it with `gpa.free`.
pub fn getAlloc(io: std.Io, gpa: std.mem.Allocator) ![:0]u8 {
    return std.process.executablePathAlloc(io, gpa);
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

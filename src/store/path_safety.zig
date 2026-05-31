const builtin = @import("builtin");
const std = @import("std");

pub const PathSafetyError = error{
    EmptyPath,
    AbsolutePath,
    BackslashPath,
    NullBytePath,
    EmptySegment,
    DotSegment,
    ParentSegment,
    StorePath,
    WindowsDrivePath,
    WindowsReservedName,
};

pub fn validateWorkspaceRelativePath(path: []const u8) PathSafetyError!void {
    if (path.len == 0) return error.EmptyPath;
    if (path[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.BackslashPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.NullBytePath;

    if (builtin.os.tag == .windows) {
        if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
            return error.WindowsDrivePath;
        }
    }

    var first = true;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.EmptySegment;
        if (std.mem.eql(u8, segment, ".")) return error.DotSegment;
        if (std.mem.eql(u8, segment, "..")) return error.ParentSegment;
        if (first and std.mem.eql(u8, segment, ".agit")) return error.StorePath;
        if (builtin.os.tag == .windows and isWindowsReservedName(segment)) return error.WindowsReservedName;
        first = false;
    }
}

fn isWindowsReservedName(segment: []const u8) bool {
    const stem = if (std.mem.indexOfScalar(u8, segment, '.')) |idx| segment[0..idx] else segment;
    if (stem.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(stem, "CON")) return true;
    if (std.ascii.eqlIgnoreCase(stem, "PRN")) return true;
    if (std.ascii.eqlIgnoreCase(stem, "AUX")) return true;
    if (std.ascii.eqlIgnoreCase(stem, "NUL")) return true;
    if (stem.len == 4 and (std.ascii.eqlIgnoreCase(stem[0..3], "COM") or std.ascii.eqlIgnoreCase(stem[0..3], "LPT"))) {
        return stem[3] >= '1' and stem[3] <= '9';
    }
    return false;
}

test "validateWorkspaceRelativePath accepts normalized nested paths" {
    try validateWorkspaceRelativePath("src/main.zig");
    try validateWorkspaceRelativePath("README.md");
}

test "validateWorkspaceRelativePath rejects escaping and ambiguous paths" {
    try std.testing.expectError(error.EmptyPath, validateWorkspaceRelativePath(""));
    try std.testing.expectError(error.AbsolutePath, validateWorkspaceRelativePath("/tmp/file"));
    try std.testing.expectError(error.BackslashPath, validateWorkspaceRelativePath("src\\main.zig"));
    try std.testing.expectError(error.NullBytePath, validateWorkspaceRelativePath("src/main\x00.zig"));
    try std.testing.expectError(error.EmptySegment, validateWorkspaceRelativePath("src//main.zig"));
    try std.testing.expectError(error.DotSegment, validateWorkspaceRelativePath("src/./main.zig"));
    try std.testing.expectError(error.ParentSegment, validateWorkspaceRelativePath("../outside.txt"));
    try std.testing.expectError(error.ParentSegment, validateWorkspaceRelativePath("src/../outside.txt"));
    try std.testing.expectError(error.StorePath, validateWorkspaceRelativePath(".agit/config.json"));
}

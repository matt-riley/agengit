const std = @import("std");

var max_file_bytes_override = std.atomic.Value(u64).init(0);

pub fn configureFromEnviron(environ: std.process.Environ) void {
    const parsed = parseMaxFileBytes(environ.getPosix("AGIT_MAX_FILE_BYTES")) orelse 0;
    max_file_bytes_override.store(parsed, .release);
}

pub fn effectiveMaxFileBytes(default_bytes: u64) u64 {
    const override = max_file_bytes_override.load(.acquire);
    return if (override == 0) default_bytes else override;
}

pub fn parseMaxFileBytes(raw: ?[]const u8) ?u64 {
    const value = raw orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseUnsigned(u64, trimmed, 10) catch return null;
    if (parsed == 0) return null;
    return parsed;
}

test "parseMaxFileBytes accepts positive integers" {
    try std.testing.expectEqual(@as(?u64, 1234), parseMaxFileBytes("1234"));
    try std.testing.expectEqual(@as(?u64, 42), parseMaxFileBytes(" 42 "));
}

test "parseMaxFileBytes rejects empty and invalid values" {
    try std.testing.expectEqual(@as(?u64, null), parseMaxFileBytes(null));
    try std.testing.expectEqual(@as(?u64, null), parseMaxFileBytes(""));
    try std.testing.expectEqual(@as(?u64, null), parseMaxFileBytes("0"));
    try std.testing.expectEqual(@as(?u64, null), parseMaxFileBytes("abc"));
}

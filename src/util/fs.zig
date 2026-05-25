const builtin = @import("builtin");
const std = @import("std");

var fsync_enabled = std.atomic.Value(bool).init(true);

pub fn configureFromEnviron(environ: std.process.Environ) void {
    const env_value = environ.getPosix("AGIT_FSYNC");
    const enabled = if (env_value) |value| !isDisabledToken(value) else true;
    fsync_enabled.store(enabled, .release);
}

pub fn fsyncEnabled() bool {
    return fsync_enabled.load(.acquire);
}

pub fn setFsyncEnabledForTesting(enabled: bool) void {
    fsync_enabled.store(enabled, .release);
}

pub fn atomicReplace(io: std.Io, af: *std.Io.File.Atomic) !void {
    try af.file.sync(io);
    try af.replace(io);
    try syncDir(io, af.dir);
}

pub fn linkDurable(io: std.Io, af: *std.Io.File.Atomic) !bool {
    try af.file.sync(io);
    af.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return false,
        else => return err,
    };
    try syncDir(io, af.dir);
    return true;
}

pub fn renameDurable(
    io: std.Io,
    src_dir: std.Io.Dir,
    src_path: []const u8,
    dst_dir: std.Io.Dir,
    dst_path: []const u8,
) !void {
    try std.Io.Dir.rename(src_dir, src_path, dst_dir, dst_path, io);
    if (src_dir.handle == dst_dir.handle) {
        try syncDir(io, src_dir);
    } else {
        try syncDir(io, src_dir);
        try syncDir(io, dst_dir);
    }
}

pub fn syncDir(io: std.Io, dir: std.Io.Dir) !void {
    _ = io;
    if (!fsyncEnabled()) return;
    switch (builtin.os.tag) {
        .windows => return,
        else => while (true) {
            switch (std.posix.errno(std.posix.system.fsync(dir.handle))) {
                .SUCCESS => return,
                .INTR => continue,
                .BADF, .INVAL, .ROFS => return,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .DQUOT => return error.DiskQuota,
                else => |err| return std.posix.unexpectedErrno(err),
            }
        },
    }
}

fn isDisabledToken(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return true;
    if (std.ascii.eqlIgnoreCase(value, "off")) return true;
    if (std.ascii.eqlIgnoreCase(value, "no")) return true;
    return false;
}

test "isDisabledToken handles known disable values" {
    try std.testing.expect(isDisabledToken("0"));
    try std.testing.expect(isDisabledToken(" false "));
    try std.testing.expect(isDisabledToken("OFF"));
    try std.testing.expect(isDisabledToken("No"));
    try std.testing.expect(!isDisabledToken("1"));
    try std.testing.expect(!isDisabledToken("true"));
    try std.testing.expect(!isDisabledToken(""));
}

test "syncDir no-ops when AGIT_FSYNC is disabled" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    setFsyncEnabledForTesting(false);
    defer setFsyncEnabledForTesting(true);

    try syncDir(io, tmp.dir);
}

const std = @import("std");
const fs_mod = @import("../util/fs.zig");

pub const Checkpoint = struct {
    instance_id: ?[]u8 = null,
    watermark: ?[]u8 = null,

    pub fn deinit(self: *Checkpoint, gpa: std.mem.Allocator) void {
        if (self.instance_id) |value| gpa.free(value);
        if (self.watermark) |value| gpa.free(value);
        self.* = undefined;
    }
};

const Disk = struct {
    version: u32 = 1,
    instance_id: ?[]const u8 = null,
    watermark: ?[]const u8 = null,
};

pub fn load(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, name: []const u8) !Checkpoint {
    var path_buf: [128]u8 = undefined;
    const path = try relativePath(&path_buf, name);
    const data = root.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(data);

    var parsed = std.json.parseFromSlice(Disk, gpa, data, .{
        .allocate = .alloc_always,
    }) catch return error.InvalidObserverCheckpoint;
    defer parsed.deinit();

    if (parsed.value.version != 1) return error.UnsupportedObserverCheckpointVersion;

    return .{
        .instance_id = if (parsed.value.instance_id) |value| try gpa.dupe(u8, value) else null,
        .watermark = if (parsed.value.watermark) |value| try gpa.dupe(u8, value) else null,
    };
}

pub fn save(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, name: []const u8, checkpoint: Checkpoint) !void {
    try root.createDirPath(io, "observers");

    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try std.json.Stringify.value(Disk{
        .instance_id = checkpoint.instance_id,
        .watermark = checkpoint.watermark,
    }, .{}, &writer.writer);

    var path_buf: [128]u8 = undefined;
    const path = try relativePath(&path_buf, name);
    var af = try root.createFileAtomic(io, path, .{ .replace = true, .make_path = false });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, writer.writer.buffered());
    try fs_mod.atomicReplace(io, &af);
}

pub fn relativePath(buf: *[128]u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "observers/{s}.json", .{name});
}

pub fn replaceField(gpa: std.mem.Allocator, field: *?[]u8, value: ?[]const u8) !void {
    if (field.*) |existing| gpa.free(existing);
    field.* = if (value) |next| try gpa.dupe(u8, next) else null;
}

test "checkpoint save/load round-trips watermark and instance id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".agit");
    var agit = try tmp.dir.openDir(std.testing.io, ".agit", .{});
    defer agit.close(std.testing.io);

    var checkpoint: Checkpoint = .{
        .instance_id = try std.testing.allocator.dupe(u8, "/tmp/fixture.json"),
        .watermark = try std.testing.allocator.dupe(u8, "evt-3"),
    };
    defer checkpoint.deinit(std.testing.allocator);

    try save(std.testing.io, agit, std.testing.allocator, "fixture", checkpoint);

    var loaded = try load(std.testing.io, agit, std.testing.allocator, "fixture");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/fixture.json", loaded.instance_id.?);
    try std.testing.expectEqualStrings("evt-3", loaded.watermark.?);
}

test "checkpoint load rejects malformed json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".agit/observers");
    var file = try tmp.dir.createFile(std.testing.io, ".agit/observers/fixture.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "{not-json");

    var agit = try tmp.dir.openDir(std.testing.io, ".agit", .{});
    defer agit.close(std.testing.io);
    try std.testing.expectError(error.InvalidObserverCheckpoint, load(std.testing.io, agit, std.testing.allocator, "fixture"));
}

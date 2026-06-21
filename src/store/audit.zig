const std = @import("std");
const store_mod = @import("store.zig");
const hash_mod = @import("hash.zig");
const pack_mod = @import("pack.zig");

const Store = store_mod.Store;

pub fn auditObjectIndex(self: *Store, io: std.Io, gpa: std.mem.Allocator) !Store.ObjectIndexAudit {
    const indexed_count: usize = @intCast(try self.index.countObjects());
    var missing_rows: usize = 0;
    var disk_hashes = std.AutoHashMap([hash_mod.hex_len]u8, void).init(gpa);
    defer disk_hashes.deinit();

    var obj_dir = self.root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{
            .indexed_complete = (try self.index.getObjectsComplete()) orelse false,
            .disk_count = 0,
            .indexed_count = indexed_count,
            .missing_rows = 0,
        },
        else => return err,
    };
    defer obj_dir.close(io);

    var walker = try obj_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path.len != 65) continue;
        var hex_buf: [64]u8 = undefined;

        @memcpy(hex_buf[0..2], entry.path[0..2]);
        @memcpy(hex_buf[2..64], entry.path[3..65]);
        if (!disk_hashes.contains(hex_buf)) {
            try disk_hashes.put(hex_buf, {});
            if (!try self.index.hasObject(&hex_buf)) missing_rows += 1;
        }
    }

    const pack_files = try pack_mod.listPackFiles(io, self.root, gpa);
    defer pack_mod.freePackFiles(gpa, pack_files);
    for (pack_files) |pack_name| {
        const entries = try pack_mod.readPackEntries(io, self.root, gpa, pack_name);
        defer pack_mod.freeParsedEntries(gpa, entries);
        for (entries) |entry| {
            const hex = entry.meta.hash.toHex();
            if (!disk_hashes.contains(hex)) {
                try disk_hashes.put(hex, {});
                if (!try self.index.hasObject(&hex)) missing_rows += 1;
            }
        }
    }

    return .{
        .indexed_complete = (try self.index.getObjectsComplete()) orelse false,
        .disk_count = disk_hashes.count(),
        .indexed_count = indexed_count,
        .missing_rows = missing_rows,
    };
}

pub fn ensureObjectIndexState(self: *Store, io: std.Io, gpa: std.mem.Allocator) !void {
    if ((try self.index.getObjectsComplete()) != null) return;

    // Count loose objects under objects/ (inline to avoid importing store.zig).
    var loose_objects: usize = 0;
    if (self.root.openDir(io, "objects", .{ .iterate = true })) |obj_dir| {
        defer obj_dir.close(io);
        var walker = try obj_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .file and entry.path.len == 65 and entry.path[2] == '/') {
                loose_objects += 1;
            }
        }
    } else |err| switch (err) {
        error.FileNotFound, error.NotDir => {},
        else => return err,
    }

    const packed_objects = try pack_mod.countEntries(io, self.root, gpa);
    try self.index.setObjectsComplete(loose_objects == 0 and packed_objects == 0);
}

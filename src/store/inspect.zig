const std = @import("std");
const object = @import("object.zig");

pub const ChangeKind = enum {
    added,
    modified,
    deleted,
    unchanged,
};

pub const ChangeCounts = struct {
    added: usize = 0,
    modified: usize = 0,
    deleted: usize = 0,
    unchanged: usize = 0,
};

pub const ComparedEntry = struct {
    kind: ChangeKind,
    path: []const u8,
    old_entry: ?object.TreeEntry = null,
    new_entry: ?object.TreeEntry = null,
};

pub const TreeComparison = struct {
    entries: []ComparedEntry,
    counts: ChangeCounts,

    pub fn deinit(self: *TreeComparison, gpa: std.mem.Allocator) void {
        gpa.free(self.entries);
        self.* = undefined;
    }
};

pub fn compareTreeEntries(
    gpa: std.mem.Allocator,
    old_entries: []const object.TreeEntry,
    new_entries: []const object.TreeEntry,
) !TreeComparison {
    var entries: std.ArrayList(ComparedEntry) = .empty;
    errdefer entries.deinit(gpa);

    var counts: ChangeCounts = .{};
    var old_index: usize = 0;
    var new_index: usize = 0;

    while (old_index < old_entries.len or new_index < new_entries.len) {
        if (old_index >= old_entries.len) {
            try appendAdded(&entries, gpa, new_entries[new_index], &counts);
            new_index += 1;
            continue;
        }
        if (new_index >= new_entries.len) {
            try appendDeleted(&entries, gpa, old_entries[old_index], &counts);
            old_index += 1;
            continue;
        }

        const old_entry = old_entries[old_index];
        const new_entry = new_entries[new_index];
        switch (std.mem.order(u8, old_entry.path, new_entry.path)) {
            .lt => {
                try appendDeleted(&entries, gpa, old_entry, &counts);
                old_index += 1;
            },
            .gt => {
                try appendAdded(&entries, gpa, new_entry, &counts);
                new_index += 1;
            },
            .eq => {
                const kind: ChangeKind = if (entriesEqual(old_entry, new_entry)) .unchanged else .modified;
                switch (kind) {
                    .modified => counts.modified += 1,
                    .unchanged => counts.unchanged += 1,
                    else => unreachable,
                }
                try entries.append(gpa, .{
                    .kind = kind,
                    .path = new_entry.path,
                    .old_entry = old_entry,
                    .new_entry = new_entry,
                });
                old_index += 1;
                new_index += 1;
            },
        }
    }

    return .{
        .entries = try entries.toOwnedSlice(gpa),
        .counts = counts,
    };
}

fn appendAdded(
    entries: *std.ArrayList(ComparedEntry),
    gpa: std.mem.Allocator,
    new_entry: object.TreeEntry,
    counts: *ChangeCounts,
) !void {
    counts.added += 1;
    try entries.append(gpa, .{
        .kind = .added,
        .path = new_entry.path,
        .new_entry = new_entry,
    });
}

fn appendDeleted(
    entries: *std.ArrayList(ComparedEntry),
    gpa: std.mem.Allocator,
    old_entry: object.TreeEntry,
    counts: *ChangeCounts,
) !void {
    counts.deleted += 1;
    try entries.append(gpa, .{
        .kind = .deleted,
        .path = old_entry.path,
        .old_entry = old_entry,
    });
}

fn entriesEqual(old_entry: object.TreeEntry, new_entry: object.TreeEntry) bool {
    return std.mem.eql(u8, old_entry.blob, new_entry.blob) and
        std.mem.eql(u8, old_entry.mode, new_entry.mode) and
        old_entry.size == new_entry.size;
}

test "compareTreeEntries reports added modified deleted and unchanged paths" {
    const old_entries = [_]object.TreeEntry{
        .{ .path = "README.md", .blob = "a" ** 64, .mode = "file", .size = 10 },
        .{ .path = "src/keep.zig", .blob = "b" ** 64, .mode = "file", .size = 20 },
        .{ .path = "src/remove.zig", .blob = "c" ** 64, .mode = "file", .size = 30 },
    };
    const new_entries = [_]object.TreeEntry{
        .{ .path = "README.md", .blob = "a" ** 64, .mode = "file", .size = 10 },
        .{ .path = "src/add.zig", .blob = "d" ** 64, .mode = "file", .size = 40 },
        .{ .path = "src/keep.zig", .blob = "e" ** 64, .mode = "file", .size = 20 },
    };

    var comparison = try compareTreeEntries(std.testing.allocator, &old_entries, &new_entries);
    defer comparison.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), comparison.counts.added);
    try std.testing.expectEqual(@as(usize, 1), comparison.counts.modified);
    try std.testing.expectEqual(@as(usize, 1), comparison.counts.deleted);
    try std.testing.expectEqual(@as(usize, 1), comparison.counts.unchanged);

    try std.testing.expectEqual(ChangeKind.unchanged, comparison.entries[0].kind);
    try std.testing.expectEqualStrings("README.md", comparison.entries[0].path);
    try std.testing.expectEqual(ChangeKind.added, comparison.entries[1].kind);
    try std.testing.expectEqualStrings("src/add.zig", comparison.entries[1].path);
    try std.testing.expectEqual(ChangeKind.modified, comparison.entries[2].kind);
    try std.testing.expectEqualStrings("src/keep.zig", comparison.entries[2].path);
    try std.testing.expectEqual(ChangeKind.deleted, comparison.entries[3].kind);
    try std.testing.expectEqualStrings("src/remove.zig", comparison.entries[3].path);
}

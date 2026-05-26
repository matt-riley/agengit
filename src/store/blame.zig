const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const diff_mod = @import("diff.zig");

pub const Hash = hash_mod.Hash;

/// One entry in a blame map: the step hash that last touched this line.
pub const BlameEntry = struct {
    step: []const u8, // 64-char lowercase hex, heap-owned
};

/// Associates each line of a file with the step that introduced it.
///
/// When obtained via `computeBlame`, all string fields are heap-allocated and
/// must be freed with `freeBlameMap`.
///
/// When obtained via `readBlame`, the returned `std.json.Parsed(BlameMap)`
/// owns all memory; call `parsed.deinit()` to release it.
pub const BlameMap = struct {
    type: []const u8 = "blame",
    path: []const u8,
    lines: []const BlameEntry,
};

/// Free all memory allocated by `computeBlame`.
/// Do NOT call on BlameMap values from `readBlame`; use `parsed.deinit()`.
pub fn freeBlameMap(gpa: std.mem.Allocator, bm: BlameMap) void {
    for (bm.lines) |e| gpa.free(@constCast(e.step));
    gpa.free(@constCast(bm.lines));
    gpa.free(@constCast(bm.path));
}

/// Compute the blame map for a file after a single step.
///
/// - `old_lines` / `new_lines`: the before/after content split by lines.
/// - `old_blame`: the blame map from the previous step, or null for the first commit.
/// - `step_hex`: 64-char lowercase hex of the current step hash.
///
/// Ownership: caller must call `freeBlameMap(gpa, result)` when done.
///
/// Returns `error.BlameLengthMismatch` when `old_blame` is provided but its
/// line count does not match `old_lines.len`.
pub fn computeBlame(
    gpa: std.mem.Allocator,
    path: []const u8,
    old_lines: []const []const u8,
    new_lines: []const []const u8,
    old_blame: ?BlameMap,
    step_hex: []const u8,
) !BlameMap {
    if (old_blame) |ob| {
        if (ob.lines.len != old_lines.len) return error.BlameLengthMismatch;
    }

    const edits = try diff_mod.diff(gpa, old_lines, new_lines);
    defer gpa.free(edits);

    var entries: std.ArrayList(BlameEntry) = .empty;
    errdefer {
        for (entries.items) |e| gpa.free(@constCast(e.step));
        entries.deinit(gpa);
    }

    var old_idx: usize = 0;
    for (edits) |edit| {
        switch (edit.op) {
            .equal => {
                const src = if (old_blame) |ob| ob.lines[old_idx].step else step_hex;
                try entries.append(gpa, .{ .step = try gpa.dupe(u8, src) });
                old_idx += 1;
            },
            .insert => {
                try entries.append(gpa, .{ .step = try gpa.dupe(u8, step_hex) });
            },
            .delete => {
                old_idx += 1;
            },
        }
    }

    return BlameMap{
        .path = try gpa.dupe(u8, path),
        .lines = try entries.toOwnedSlice(gpa),
    };
}

/// Serialize a BlameMap and write it to the object store.  Returns the hash.
pub fn writeBlameDetailed(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    bm: BlameMap,
) !object.WriteDetails {
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(bm, .{}, &aw.writer);
    const data = aw.writer.buffered();
    return object.writeDetailed(io, root, data);
}

pub fn writeBlame(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    bm: BlameMap,
) !Hash {
    return (try writeBlameDetailed(io, root, gpa, bm)).hash;
}

/// Read a BlameMap from the object store by hash.
/// Caller must call `parsed.deinit()` to release memory.
pub fn readBlame(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    h: Hash,
) !std.json.Parsed(BlameMap) {
    const data = try object.read(io, root, gpa, h);
    defer gpa.free(data);
    return std.json.parseFromSlice(BlameMap, gpa, data, .{ .allocate = .alloc_always });
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "computeBlame: first commit attributes all lines to step" {
    const gpa = std.testing.allocator;
    const lines = [_][]const u8{ "alpha", "beta", "gamma" };
    const step_hex = "a" ** 64;
    const bm = try computeBlame(gpa, "src/foo.zig", &.{}, &lines, null, step_hex);
    defer freeBlameMap(gpa, bm);

    try std.testing.expectEqual(@as(usize, 3), bm.lines.len);
    for (bm.lines) |e| try std.testing.expectEqualStrings(step_hex, e.step);
}

test "computeBlame: preserves blame for unchanged lines" {
    const gpa = std.testing.allocator;
    const old_lines = [_][]const u8{ "alpha", "beta" };
    const new_lines = [_][]const u8{ "alpha", "beta", "gamma" };
    const step1 = "1" ** 64;
    const step2 = "2" ** 64;

    const bm1 = try computeBlame(gpa, "f.zig", &.{}, &old_lines, null, step1);
    defer freeBlameMap(gpa, bm1);

    const bm2 = try computeBlame(gpa, "f.zig", &old_lines, &new_lines, bm1, step2);
    defer freeBlameMap(gpa, bm2);

    try std.testing.expectEqual(@as(usize, 3), bm2.lines.len);
    try std.testing.expectEqualStrings(step1, bm2.lines[0].step);
    try std.testing.expectEqualStrings(step1, bm2.lines[1].step);
    try std.testing.expectEqualStrings(step2, bm2.lines[2].step);
}

test "computeBlame: returns error on length mismatch" {
    const gpa = std.testing.allocator;
    const old_lines = [_][]const u8{"line"};
    const new_lines = [_][]const u8{"line"};
    const step1 = "1" ** 64;

    // Create a blame map with 1 entry.
    const bm1 = try computeBlame(gpa, "f", &.{}, &old_lines, null, step1);
    defer freeBlameMap(gpa, bm1);

    // Pass it with mismatched old_lines (empty vs 1-entry blame).
    const err = computeBlame(gpa, "f", &.{}, &new_lines, bm1, step1);
    try std.testing.expectError(error.BlameLengthMismatch, err);
}

test "writeBlame and readBlame round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const lines = [_][]const u8{ "x", "y" };
    const step_hex = "b" ** 64;
    const bm = try computeBlame(gpa, "a.zig", &.{}, &lines, null, step_hex);
    defer freeBlameMap(gpa, bm);

    const h = try writeBlame(io, tmp.dir, gpa, bm);
    var parsed = try readBlame(io, tmp.dir, gpa, h);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("blame", parsed.value.type);
    try std.testing.expectEqualStrings("a.zig", parsed.value.path);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.lines.len);
    try std.testing.expectEqualStrings(step_hex, parsed.value.lines[0].step);
}

const std = @import("std");
const hash_mod = @import("hash.zig");
const file_lock = @import("../util/file_lock.zig");

pub const Hash = hash_mod.Hash;

/// Build the ref path (relative to the store root) for a session HEAD pointer.
///
/// Path format: refs/sessions/<origin-hex>/<session-id-hex>
///
/// Both components are hex-encoded so the path is safe on Windows and avoids
/// any special characters present in origin URLs or session identifiers.
///
/// Caller owns the returned slice.
pub fn buildRefPath(gpa: std.mem.Allocator, origin: []const u8, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "refs/sessions/{x}/{x}", .{ origin, session_id });
}

/// Write `new_hash` to `path` (relative to `root`) atomically.
/// Does not acquire a lock — caller must already hold one.
pub fn writeRefToPath(
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
    new_hash: Hash,
) !void {
    const hex = new_hash.toHex();
    var content_buf: [65]u8 = undefined;
    @memcpy(content_buf[0..64], &hex);
    content_buf[64] = '\n';

    var af = try root.createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer af.deinit(io);

    try af.file.writeStreamingAll(io, content_buf[0..65]);
    try af.file.sync(io);
    try af.replace(io);
}

/// Read the current HEAD hash for a session. Returns null if no ref exists yet.
pub fn readSessionRef(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    origin: []const u8,
    session_id: []const u8,
) !?Hash {
    const path = try buildRefPath(gpa, origin, session_id);
    defer gpa.free(path);

    const data = root.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer gpa.free(data);

    const trimmed = std.mem.trim(u8, data, " \r\n");
    return try Hash.fromHex(trimmed);
}

/// Atomically (crash-safe) update the session HEAD ref to `new_hash`.
/// Acquires a lock for the duration of the write.
pub fn writeSessionRef(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    origin: []const u8,
    session_id: []const u8,
    new_hash: Hash,
) !void {
    const path = try buildRefPath(gpa, origin, session_id);
    defer gpa.free(path);

    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
    defer gpa.free(lock_path);

    // Ensure parent dirs exist.
    const parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    if (parent_end > 0) {
        try root.createDirPath(io, path[0..parent_end]);
    }

    var lock = try file_lock.LockFile.acquire(io, root, lock_path, .{});
    defer lock.release(io);

    const hex = new_hash.toHex();
    var content_buf: [65]u8 = undefined;
    @memcpy(content_buf[0..64], &hex);
    content_buf[64] = '\n';

    var af = try root.createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer af.deinit(io);

    try af.file.writeStreamingAll(io, content_buf[0..65]);
    try af.file.sync(io);
    try af.replace(io);
}

/// Compare-and-swap: update the session HEAD ref from `expected` to `new_hash`.
///
/// - If `expected` is null, only succeeds when no ref exists yet (create).
/// - If `expected` is a Hash, only succeeds when the stored hash matches.
/// - Returns true on success, false if the current value does not match `expected`.
pub fn casSessionRef(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    origin: []const u8,
    session_id: []const u8,
    expected: ?Hash,
    new_hash: Hash,
) !bool {
    const path = try buildRefPath(gpa, origin, session_id);
    defer gpa.free(path);

    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
    defer gpa.free(lock_path);

    const parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    if (parent_end > 0) {
        try root.createDirPath(io, path[0..parent_end]);
    }

    var lock = try file_lock.LockFile.acquire(io, root, lock_path, .{});
    defer lock.release(io);

    // Read current value while holding the lock.
    const current_data = root.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (current_data) |d| gpa.free(d);

    const current: ?Hash = if (current_data) |d| blk: {
        const trimmed = std.mem.trim(u8, d, " \r\n");
        break :blk Hash.fromHex(trimmed) catch return error.CorruptRef;
    } else null;

    // Check the expected value.
    const matches = if (expected) |exp|
        if (current) |cur| cur.eql(exp) else false
    else
        current == null;

    if (!matches) return false;

    const hex = new_hash.toHex();
    var content_buf: [65]u8 = undefined;
    @memcpy(content_buf[0..64], &hex);
    content_buf[64] = '\n';

    var af = try root.createFileAtomic(io, path, .{ .replace = true, .make_path = true });
    defer af.deinit(io);

    try af.file.writeStreamingAll(io, content_buf[0..65]);
    try af.file.sync(io);
    try af.replace(io);

    return true;
}

test "writeSessionRef and readSessionRef" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const h = hash_mod.Hash.ofBytes("step data");
    try writeSessionRef(io, tmp.dir, gpa, "github.com/u/r", "session-1", h);

    const read_back = try readSessionRef(io, tmp.dir, gpa, "github.com/u/r", "session-1");
    try std.testing.expect(read_back != null);
    try std.testing.expect(h.eql(read_back.?));
}

test "readSessionRef returns null for missing ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const result = try readSessionRef(io, tmp.dir, gpa, "origin", "nosession");
    try std.testing.expect(result == null);
}

test "casSessionRef create and update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const h1 = hash_mod.Hash.ofBytes("step 1");
    const h2 = hash_mod.Hash.ofBytes("step 2");

    // Create: expected=null.
    const ok1 = try casSessionRef(io, tmp.dir, gpa, "origin", "s1", null, h1);
    try std.testing.expect(ok1);

    // Wrong expected: should fail.
    const ok2 = try casSessionRef(io, tmp.dir, gpa, "origin", "s1", null, h2);
    try std.testing.expect(!ok2);

    // Correct expected: should succeed.
    const ok3 = try casSessionRef(io, tmp.dir, gpa, "origin", "s1", h1, h2);
    try std.testing.expect(ok3);

    const current = try readSessionRef(io, tmp.dir, gpa, "origin", "s1");
    try std.testing.expect(current != null);
    try std.testing.expect(h2.eql(current.?));
}

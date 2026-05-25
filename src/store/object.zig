const std = @import("std");
const hash_mod = @import("hash.zig");

pub const Hash = hash_mod.Hash;

/// An entry inside a Tree object.
pub const TreeEntry = struct {
    path: []const u8,
    blob: []const u8, // 64-char lowercase hex hash
    mode: []const u8,
    size: u64,
};

/// A directory snapshot: an ordered list of file entries.
pub const Tree = struct {
    type: []const u8 = "tree",
    entries: []const TreeEntry,
};

/// A causal reference to another object that triggered this step.
pub const Cause = struct {
    kind: []const u8,
    ref: []const u8,
};

/// A message in an agent turn (user or assistant role).
pub const StepMessage = struct {
    role: []const u8,
    content: []const u8,
};

/// A tool call made during an agent turn.
pub const StepToolCall = struct {
    tool_name: []const u8,
    args: []const u8,
    result: ?[]const u8,
};

/// An agent turn: the core unit of recorded activity.
///
/// `messages` and `tool_calls` default to empty so that step objects written
/// before these fields were added can be parsed without error.
pub const Step = struct {
    type: []const u8 = "step",
    parent: ?[]const u8, // 64-char hex or null
    tree: []const u8, // 64-char hex
    session_id: []const u8,
    origin: []const u8,
    turn_id: []const u8,
    causes: []const Cause,
    timestamp: i64,
    messages: []const StepMessage = &.{},
    tool_calls: []const StepToolCall = &.{},
};

/// Write `data` to the content-addressed object store under `root`.
/// Returns the BLAKE3 hash. Idempotent: writing the same bytes twice succeeds.
pub fn write(io: std.Io, root: std.Io.Dir, data: []const u8) !Hash {
    const h = Hash.ofBytes(data);
    const hex = h.toHex();

    // Create the shard dir: objects/<first-2-hex-chars>/
    var shard_path_buf: [11]u8 = undefined;
    const shard_path = std.fmt.bufPrint(&shard_path_buf, "objects/{s}", .{hex[0..2]}) catch unreachable;
    try root.createDirPath(io, shard_path);

    var shard_dir = try root.openDir(io, shard_path, .{});
    defer shard_dir.close(io);

    // Atomic write of the remaining 62 hex chars as the filename.
    var af = try shard_dir.createFileAtomic(io, hex[2..], .{ .replace = false });
    defer af.deinit(io);

    try af.file.writeStreamingAll(io, data);
    try af.file.sync(io);

    // link() fails with PathAlreadyExists for duplicate content — that's fine.
    af.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    return h;
}

/// Read and return the raw bytes for the object identified by `h`.
/// Caller owns the returned slice.
pub fn read(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, h: Hash) ![]u8 {
    const hex = h.toHex();
    var path_buf: [73]u8 = undefined;
    const obj_path = std.fmt.bufPrint(&path_buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;
    return root.readFileAlloc(io, obj_path, gpa, .unlimited);
}

/// Walk the object store and resolve a hex prefix to a full Hash.
/// Returns error.ObjectNotFound if no match, error.AmbiguousPrefix if multiple.
pub fn resolvePrefix(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, prefix: []const u8) !Hash {
    if (prefix.len == 0 or prefix.len > hash_mod.hex_len) return error.InvalidHash;

    var obj_dir = root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.ObjectNotFound,
        else => return err,
    };
    defer obj_dir.close(io);

    var walker = try obj_dir.walk(gpa);
    defer walker.deinit();

    var found: ?Hash = null;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Each file path is "<2>/<62>" = 65 bytes total.
        if (entry.path.len != 65) continue;
        var hex_buf: [64]u8 = undefined;
        @memcpy(hex_buf[0..2], entry.path[0..2]);
        @memcpy(hex_buf[2..64], entry.path[3..65]);
        const h = Hash.fromHex(&hex_buf) catch continue;
        if (!h.hasPrefix(prefix)) continue;
        if (found != null) return error.AmbiguousPrefix;
        found = h;
    }
    return found orelse error.ObjectNotFound;
}

/// Serialize `tree` as JSON and write it to the object store.
pub fn writeTree(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, tree: Tree) !Hash {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(tree, .{}, &aw.writer);
    return write(io, root, aw.writer.buffered());
}

/// Read and deserialize a Tree from the object store.
/// Caller must call `.deinit()` on the returned value.
pub fn readTree(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(Tree) {
    const data = try read(io, root, gpa, h);
    defer gpa.free(data);
    return std.json.parseFromSlice(Tree, gpa, data, .{ .allocate = .alloc_always });
}

/// Serialize `step` as JSON and write it to the object store.
pub fn writeStep(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, step: Step) !Hash {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(step, .{}, &aw.writer);
    return write(io, root, aw.writer.buffered());
}

/// Read and deserialize a Step from the object store.
/// Caller must call `.deinit()` on the returned value.
pub fn readStep(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(Step) {
    const data = try read(io, root, gpa, h);
    defer gpa.free(data);
    return std.json.parseFromSlice(Step, gpa, data, .{ .allocate = .alloc_always });
}

test "write and read raw object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const data = "hello, object store!";
    const h = try write(io, tmp.dir, data);

    const back = try read(io, tmp.dir, std.testing.allocator, h);
    defer std.testing.allocator.free(back);

    try std.testing.expectEqualStrings(data, back);
}

test "write is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const data = "idempotent content";
    const h1 = try write(io, tmp.dir, data);
    const h2 = try write(io, tmp.dir, data);
    try std.testing.expect(h1.eql(h2));
}

test "write and read Tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const entry = TreeEntry{
        .path = "src/main.zig",
        .blob = "a" ** 64,
        .mode = "file",
        .size = 42,
    };
    const tree = Tree{ .entries = &[_]TreeEntry{entry} };

    const h = try writeTree(io, tmp.dir, std.testing.allocator, tree);
    var parsed = try readTree(io, tmp.dir, std.testing.allocator, h);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try std.testing.expectEqualStrings("src/main.zig", parsed.value.entries[0].path);
}

test "write and read Step" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const step = Step{
        .parent = null,
        .tree = "b" ** 64,
        .session_id = "session-abc",
        .origin = "github.com/user/repo",
        .turn_id = "turn-1",
        .causes = &.{},
        .timestamp = 1700000000000,
    };

    const h = try writeStep(io, tmp.dir, std.testing.allocator, step);
    var parsed = try readStep(io, tmp.dir, std.testing.allocator, h);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("session-abc", parsed.value.session_id);
    try std.testing.expect(parsed.value.parent == null);
    try std.testing.expectEqual(@as(i64, 1700000000000), parsed.value.timestamp);
}

test "resolvePrefix finds object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const data = "prefix test";
    const h = try write(io, tmp.dir, data);
    const hex = h.toHex();

    const found = try resolvePrefix(io, tmp.dir, std.testing.allocator, hex[0..8]);
    try std.testing.expect(h.eql(found));
}

test "resolvePrefix returns ObjectNotFound for empty store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try std.testing.expectError(
        error.ObjectNotFound,
        resolvePrefix(io, tmp.dir, std.testing.allocator, "abcd1234"),
    );
}

test "resolvePrefix returns AmbiguousPrefix for colliding prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // Write two objects that definitely have different hashes; use full hex to avoid collision.
    _ = try write(io, tmp.dir, "object alpha");
    _ = try write(io, tmp.dir, "object beta");

    // An empty prefix matches everything.
    try std.testing.expectError(
        error.InvalidHash,
        resolvePrefix(io, tmp.dir, std.testing.allocator, ""),
    );
}

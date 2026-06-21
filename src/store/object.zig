const std = @import("std");
const hash_mod = @import("hash.zig");
const fs_mod = @import("../util/fs.zig");

pub const Hash = hash_mod.Hash;

pub const WriteDetails = struct {
    hash: Hash,
    size: usize,
};

pub const PrefixResolution = union(enum) {
    not_found,
    unique: Hash,
    ambiguous: [2]Hash,
};

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

pub const GitContext = struct {
    commit: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    dirty: ?bool = null,
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
    model: ?[]const u8 = null,
    turn_id: []const u8,
    causes: []const Cause,
    timestamp: i64,
    messages: []const StepMessage = &.{},
    tool_calls: []const StepToolCall = &.{},
    outcome: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
};

/// Write `data` to the content-addressed object store under `root`.
/// Returns the BLAKE3 hash. Idempotent: writing the same bytes twice succeeds.
pub fn writeDetailed(io: std.Io, root: std.Io.Dir, data: []const u8) !WriteDetails {
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
    _ = try fs_mod.linkDurable(io, &af);

    return .{
        .hash = h,
        .size = data.len,
    };
}

pub fn write(io: std.Io, root: std.Io.Dir, data: []const u8) !Hash {
    return (try writeDetailed(io, root, data)).hash;
}

/// Read and return the raw bytes for the object identified by `h`.
/// Caller owns the returned slice.
pub fn read(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, h: Hash) ![]u8 {
    const hex = h.toHex();
    var path_buf: [73]u8 = undefined;
    const obj_path = std.fmt.bufPrint(&path_buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;
    return root.readFileAlloc(io, obj_path, gpa, .unlimited);
}

fn jsonTopLevelTypeIs(data: []const u8, expected: []const u8) bool {
    const gpa = std.heap.page_allocator;
    var parsed = std.json.parseFromSlice(struct { type: ?[]const u8 = null }, gpa, data, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    const t = parsed.value.type orelse return false;
    return std.mem.eql(u8, t, expected);
}

pub fn detectKind(data: []const u8) []const u8 {
    if (std.mem.indexOf(u8, data, "\"type\":\"tree\"") != null and jsonTopLevelTypeIs(data, "tree")) return "tree";
    if (std.mem.indexOf(u8, data, "\"type\":\"step\"") != null and jsonTopLevelTypeIs(data, "step")) return "step";
    if (std.mem.indexOf(u8, data, "\"type\":\"blame\"") != null and jsonTopLevelTypeIs(data, "blame")) return "blame";
    if (std.mem.indexOf(u8, data, "\"type\":\"eval\"") != null and jsonTopLevelTypeIs(data, "eval")) return "eval";
    return "blob";
}

fn updateResolution(current: *PrefixResolution, h: Hash) void {
    switch (current.*) {
        .not_found => current.* = .{ .unique = h },
        .unique => |first| current.* = .{ .ambiguous = .{ first, h } },
        .ambiguous => {},
    }
}

/// Walk the object store and resolve a hex prefix to a full Hash or a pair of candidates.
pub fn resolvePrefixDetailed(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, prefix: []const u8) !PrefixResolution {
    if (prefix.len == 0 or prefix.len > hash_mod.hex_len) return error.InvalidHash;

    var found: PrefixResolution = .not_found;

    if (prefix.len >= 2) {
        var shard_path_buf: [11]u8 = undefined;
        const shard_path = std.fmt.bufPrint(&shard_path_buf, "objects/{s}", .{prefix[0..2]}) catch unreachable;
        var shard_dir = root.openDir(io, shard_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .not_found,
            else => return err,
        };
        defer shard_dir.close(io);

        var iter = shard_dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len != 62) continue;
            var hex_buf: [64]u8 = undefined;
            @memcpy(hex_buf[0..2], prefix[0..2]);
            @memcpy(hex_buf[2..64], entry.name[0..62]);
            const h = Hash.fromHex(&hex_buf) catch continue;
            if (!h.hasPrefix(prefix)) continue;
            updateResolution(&found, h);
        }
        return found;
    }

    var obj_dir = root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .not_found,
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
        const h = Hash.fromHex(&hex_buf) catch continue;
        if (!h.hasPrefix(prefix)) continue;
        updateResolution(&found, h);
    }
    return found;
}

/// Walk the object store and resolve a hex prefix to a full Hash.
/// Returns error.ObjectNotFound if no match, error.AmbiguousPrefix if multiple.
pub fn resolvePrefix(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, prefix: []const u8) !Hash {
    return switch (try resolvePrefixDetailed(io, root, gpa, prefix)) {
        .not_found => error.ObjectNotFound,
        .unique => |h| h,
        .ambiguous => error.AmbiguousPrefix,
    };
}

/// Serialize `tree` as JSON and write it to the object store.
pub fn writeTreeDetailed(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, tree: Tree) !WriteDetails {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(tree, .{}, &aw.writer);
    return writeDetailed(io, root, aw.writer.buffered());
}

pub fn writeTree(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, tree: Tree) !Hash {
    return (try writeTreeDetailed(io, root, gpa, tree)).hash;
}

/// Read and deserialize a Tree from the object store.
/// Caller must call `.deinit()` on the returned value.
pub fn readTree(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(Tree) {
    const data = try read(io, root, gpa, h);
    defer gpa.free(data);
    return std.json.parseFromSlice(Tree, gpa, data, .{ .allocate = .alloc_always });
}

/// Serialize `step` as JSON and write it to the object store.
pub fn writeStepDetailed(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, step: Step) !WriteDetails {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(step, .{}, &aw.writer);
    return writeDetailed(io, root, aw.writer.buffered());
}

pub fn writeStep(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, step: Step) !Hash {
    return (try writeStepDetailed(io, root, gpa, step)).hash;
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

test "step JSON without model parses with null model" {
    const gpa = std.testing.allocator;
    const raw =
        \\{
        \\  "type": "step",
        \\  "parent": null,
        \\  "tree": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "session_id": "sess-1",
        \\  "origin": "codex",
        \\  "turn_id": "turn-1",
        \\  "causes": [],
        \\  "timestamp": 1000
        \\}
    ;

    var parsed = try std.json.parseFromSlice(Step, gpa, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.model == null);
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

test "read Step without optional metadata defaults fields to null" {
    var parsed = try std.json.parseFromSlice(Step, std.testing.allocator,
        \\{"type":"step","parent":null,"tree":"b","session_id":"session-abc","origin":"claude","turn_id":"turn-1","causes":[],"timestamp":1700000000000}
    , .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.outcome == null);
    try std.testing.expect(parsed.value.git_commit == null);
    try std.testing.expect(parsed.value.git_branch == null);
    try std.testing.expect(parsed.value.git_dirty == null);
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

test "resolvePrefixDetailed returns ambiguous candidates for colliding prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var first_by_nibble: [16]?Hash = .{null} ** 16;
    var collision_prefix: ?u8 = null;
    var expected: [2]Hash = undefined;

    var i: usize = 0;
    while (collision_prefix == null) : (i += 1) {
        var data_buf: [32]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "object-{d}", .{i});
        const h = try write(io, tmp.dir, data);
        const hex = h.toHex();
        const nibble = std.fmt.charToDigit(hex[0], 16) catch unreachable;
        if (first_by_nibble[nibble]) |existing| {
            collision_prefix = hex[0];
            expected = .{ existing, h };
        } else {
            first_by_nibble[nibble] = h;
        }
    }

    var prefix_buf = [_]u8{collision_prefix.?};
    const resolution = try resolvePrefixDetailed(io, tmp.dir, std.testing.allocator, &prefix_buf);
    switch (resolution) {
        .ambiguous => |matches| {
            try std.testing.expect(
                (matches[0].eql(expected[0]) and matches[1].eql(expected[1])) or
                    (matches[0].eql(expected[1]) and matches[1].eql(expected[0])),
            );
        },
        else => return error.TestUnexpectedResult,
    }
}

test "detectKind classifies structured and raw objects" {
    try std.testing.expectEqualStrings("tree", detectKind("{\"type\":\"tree\"}"));
    try std.testing.expectEqualStrings("step", detectKind("{\"type\":\"step\"}"));
    try std.testing.expectEqualStrings("blame", detectKind("{\"type\":\"blame\"}"));
    try std.testing.expectEqualStrings("step", detectKind("{\"type\":\"step\",\"timestamp\":1}"));
    try std.testing.expectEqualStrings("blame", detectKind("{\"type\":\"blame\",\"lines\":[]}"));
    try std.testing.expectEqualStrings("eval", detectKind("{\"type\":\"eval\"}"));
    try std.testing.expectEqualStrings("eval", detectKind("{\"type\":\"eval\",\"assessment\":{}}"));
    try std.testing.expectEqualStrings("blob", detectKind("plain text"));
}

test "detectKind ignores literal type string inside a blob" {
    const blob = "// hook payload contains \"type\":\"step\" for routing\nfunction record() {}";
    try std.testing.expectEqualStrings("blob", detectKind(blob));
}

/// Serialize an eval object and write it to the content-addressed store.
pub fn writeEvalDetailed(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, eval: anytype) !WriteDetails {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(eval, .{}, &aw.writer);
    return writeDetailed(io, root, aw.writer.buffered());
}

pub fn writeEval(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, eval: anytype) !Hash {
    return (try writeEvalDetailed(io, root, gpa, eval)).hash;
}

/// Read and deserialize an EvalObject from the object store.
/// Caller must call `.deinit()` on the returned value.
pub fn readEval(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, h: Hash, comptime T: type) !std.json.Parsed(T) {
    const data = try read(io, root, gpa, h);
    defer gpa.free(data);
    return std.json.parseFromSlice(T, gpa, data, .{ .allocate = .alloc_always });
}

test "writeEval and readEval round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const EvalTest = struct {
        type: []const u8 = "eval",
        classification: []const u8,
        score: i64,
    };
    const eval_obj = EvalTest{ .classification = "good", .score = 85 };

    const h = try writeEval(io, tmp.dir, std.testing.allocator, eval_obj);
    var parsed = try readEval(io, tmp.dir, std.testing.allocator, h, EvalTest);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("eval", parsed.value.type);
    try std.testing.expectEqualStrings("good", parsed.value.classification);
    try std.testing.expectEqual(@as(i64, 85), parsed.value.score);
}

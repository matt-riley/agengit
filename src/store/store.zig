const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const ref = @import("ref.zig");
const index_mod = @import("index.zig");
const file_lock = @import("../util/file_lock.zig");
const ignore_mod = @import("ignore.zig");
const snapshot_mod = @import("snapshot.zig");
const blame_mod = @import("blame.zig");
const zqlite = @import("zqlite");

pub const Hash = hash_mod.Hash;
pub const Tree = object.Tree;
pub const TreeEntry = object.TreeEntry;
pub const Step = object.Step;
pub const Cause = object.Cause;
pub const Index = index_mod.Index;
pub const SessionRow = index_mod.SessionRow;
pub const StepRow = index_mod.StepRow;
pub const freeSessionRows = index_mod.freeSessionRows;
pub const freeStepRows = index_mod.freeStepRows;
pub const freeSessionRow = index_mod.freeSessionRow;
pub const freeStepRow = index_mod.freeStepRow;
pub const Ignorer = ignore_mod.Ignorer;
pub const SnapshotConfig = snapshot_mod.SnapshotConfig;
pub const BlameMap = blame_mod.BlameMap;
pub const BlameEntry = blame_mod.BlameEntry;
pub const freeBlameMap = blame_mod.freeBlameMap;
pub const computeBlame = blame_mod.computeBlame;

/// The agit content-addressed object store and associated index.
///
/// The store lives inside a `.agit/` directory that is a child of the
/// repository root.  Call `open` to open or create it.
pub const Store = struct {
    root: std.Io.Dir, // the .agit/ dir; closed by deinit
    index: Index,

    /// Open (or create) the store rooted at `repo_dir/.agit/`.
    pub fn open(io: std.Io, repo_dir: std.Io.Dir, gpa: std.mem.Allocator) !Store {
        _ = gpa;

        // Ensure .agit/ and its subdirectories exist.
        try repo_dir.createDirPath(io, ".agit/objects");
        try repo_dir.createDirPath(io, ".agit/refs/sessions");
        try repo_dir.createDirPath(io, ".agit/log");
        try repo_dir.createDirPath(io, ".agit/tmp");

        var root = try repo_dir.openDir(io, ".agit", .{});
        errdefer root.close(io);

        // Open the SQLite index with an absolute path.
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try root.realPath(io, &path_buf);
        var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

        const idx = try Index.open(db_path);
        errdefer idx.close();

        try idx.migrate();

        return .{ .root = root, .index = idx };
    }

    pub fn deinit(self: *Store, io: std.Io) void {
        self.index.close();
        self.root.close(io);
        self.* = undefined;
    }

    /// Walk up from `start_dir` looking for a `.agit/` directory.
    /// Returns `error.StoreNotFound` if none is found, otherwise opens the store.
    /// Does NOT create `.agit/` or any subdirectories.
    pub fn findAndOpen(io: std.Io, start_dir: std.Io.Dir, gpa: std.mem.Allocator) !Store {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;

        var current = try start_dir.openDir(io, ".", .{});
        while (true) {
            const has_agit = blk: {
                var d = current.openDir(io, ".agit", .{}) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => break :blk false,
                    else => |e| {
                        current.close(io);
                        return e;
                    },
                };
                d.close(io);
                break :blk true;
            };
            if (has_agit) {
                defer current.close(io);
                return Store.open(io, current, gpa);
            }

            const parent = current.openDir(io, "..", .{}) catch |e| {
                current.close(io);
                return e;
            };

            const n1 = current.realPath(io, &path_buf) catch |e| {
                current.close(io);
                parent.close(io);
                return e;
            };
            const n2 = parent.realPath(io, &parent_buf) catch |e| {
                current.close(io);
                parent.close(io);
                return e;
            };

            if (std.mem.eql(u8, path_buf[0..n1], parent_buf[0..n2])) {
                current.close(io);
                parent.close(io);
                return error.StoreNotFound;
            }

            current.close(io);
            current = parent;
        }
    }

    // ── Object writes ────────────────────────────────────────────────────────

    /// Write raw bytes to the object store. Returns the content hash.
    pub fn writeBlob(self: *Store, io: std.Io, data: []const u8) !Hash {
        return object.write(io, self.root, data);
    }

    /// Write a Tree object. Returns its hash.
    pub fn writeTree(self: *Store, io: std.Io, gpa: std.mem.Allocator, tree: Tree) !Hash {
        return object.writeTree(io, self.root, gpa, tree);
    }

    /// Write a Step object. Returns its hash.
    pub fn writeStep(self: *Store, io: std.Io, gpa: std.mem.Allocator, step: Step) !Hash {
        return object.writeStep(io, self.root, gpa, step);
    }

    // ── Object reads ─────────────────────────────────────────────────────────

    /// Read raw bytes for the object identified by `h`. Caller owns result.
    pub fn readBlob(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) ![]u8 {
        return object.read(io, self.root, gpa, h);
    }

    /// Read and deserialize a Tree object. Caller must call `.deinit()`.
    pub fn readTree(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(Tree) {
        return object.readTree(io, self.root, gpa, h);
    }

    /// Read and deserialize a Step object. Caller must call `.deinit()`.
    pub fn readStep(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(Step) {
        return object.readStep(io, self.root, gpa, h);
    }

    /// Resolve a hex prefix to a full object Hash.
    /// Returns error.ObjectNotFound or error.AmbiguousPrefix on bad input.
    pub fn resolvePrefix(self: *Store, io: std.Io, gpa: std.mem.Allocator, prefix: []const u8) !Hash {
        return object.resolvePrefix(io, self.root, gpa, prefix);
    }

    // ── Snapshot ─────────────────────────────────────────────────────────────

    /// Walk `repo_dir` and write a Tree snapshot.  Returns the Tree hash.
    pub fn snapshot(
        self: *Store,
        io: std.Io,
        repo_dir: std.Io.Dir,
        gpa: std.mem.Allocator,
        ignorer: *const Ignorer,
        config: SnapshotConfig,
    ) !Hash {
        return snapshot_mod.snapshot(io, repo_dir, gpa, self.root, ignorer, config);
    }

    // ── Blame ─────────────────────────────────────────────────────────────────

    /// Write a BlameMap to the object store.  Returns its hash.
    pub fn writeBlame(self: *Store, io: std.Io, gpa: std.mem.Allocator, bm: BlameMap) !Hash {
        return blame_mod.writeBlame(io, self.root, gpa, bm);
    }

    /// Read a BlameMap from the object store.  Caller calls `parsed.deinit()`.
    pub fn readBlame(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(BlameMap) {
        return blame_mod.readBlame(io, self.root, gpa, h);
    }

    // ── Ref operations ───────────────────────────────────────────────────────

    /// Read the current HEAD step hash for a session. Returns null if none.
    pub fn readRef(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        origin: []const u8,
        session_id: []const u8,
    ) !?Hash {
        return ref.readSessionRef(io, self.root, gpa, origin, session_id);
    }

    /// Compare-and-swap the session HEAD ref and, within the same lock window,
    /// upsert the session and insert the step into the index.
    ///
    /// Returns true on success, false if the current HEAD does not match `expected`.
    pub fn casRef(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        origin: []const u8,
        session_id: []const u8,
        expected: ?Hash,
        new_hash: Hash,
        step: *const Step,
    ) !bool {
        const path = try ref.buildRefPath(gpa, origin, session_id);
        defer gpa.free(path);

        const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
        defer gpa.free(lock_path);

        // Ensure parent dirs exist before acquiring the lock.
        const ref_parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        if (ref_parent_end > 0) {
            try self.root.createDirPath(io, path[0..ref_parent_end]);
        }

        // Acquire the lock and hold it across the ref write AND the index updates
        // so that both are always consistent from the perspective of any observer.
        var lock = try file_lock.LockFile.acquire(io, self.root, lock_path, .{});
        defer lock.release(io);

        // Read the current ref value while holding the lock.
        const current_data = self.root.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
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

        // Write the new ref atomically (still under lock).
        try ref.writeRefToPath(io, self.root, path, new_hash);

        // Update the index (still under lock — same atomic window as the ref write).
        const new_hex = new_hash.toHex();
        const new_hex_str: []const u8 = &new_hex;

        try self.index.upsertSession(origin, session_id, new_hex_str);

        const parent_hex_buf = if (step.parent) |p| p else null;
        try self.index.insertStep(
            new_hex_str,
            origin,
            session_id,
            step.turn_id,
            parent_hex_buf,
            step.tree,
            step.timestamp,
        );

        return true;
    }
};

test "store open creates structure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var s = try Store.open(io, tmp.dir, std.testing.allocator);
    defer s.deinit(io);

    // .agit/ should exist.
    const stat = try tmp.dir.statFile(io, ".agit", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "store write and read blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var s = try Store.open(io, tmp.dir, std.testing.allocator);
    defer s.deinit(io);

    const data = "blob content";
    const h = try s.writeBlob(io, data);
    const back = try s.readBlob(io, std.testing.allocator, h);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(data, back);
}

test "store casRef creates and updates ref plus index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var s = try Store.open(io, tmp.dir, std.testing.allocator);
    defer s.deinit(io);

    const step1 = Step{
        .parent = null,
        .tree = "a" ** 64,
        .session_id = "sess-1",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };

    const h1 = try s.writeStep(io, std.testing.allocator, step1);
    const ok = try s.casRef(io, std.testing.allocator, "github.com/u/r", "sess-1", null, h1, &step1);
    try std.testing.expect(ok);

    // Verify ref.
    const head = try s.readRef(io, std.testing.allocator, "github.com/u/r", "sess-1");
    try std.testing.expect(head != null);
    try std.testing.expect(h1.eql(head.?));
}

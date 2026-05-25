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
pub const StepMessage = object.StepMessage;
pub const StepToolCall = object.StepToolCall;
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
pub const finalize_retries_metric_key = "metrics.finalize_retries_total";
pub const finalize_objects_metric_key = "metrics.finalize_objects_written_total";

/// The agit content-addressed object store and associated index.
///
/// The store lives inside a `.agit/` directory that is a child of the
/// repository root.  Call `open` to open or create it.
pub const Store = struct {
    root: std.Io.Dir, // the .agit/ dir; closed by deinit
    index: Index,

    /// Open (or create) the store rooted at `repo_dir/.agit/`.
    pub fn open(io: std.Io, repo_dir: std.Io.Dir, gpa: std.mem.Allocator) !Store {
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
        var store = Store{ .root = root, .index = idx };
        errdefer store.deinit(io);

        _ = try store.reconcile(io, gpa, .repair);
        return store;
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

    pub const ReconcileMode = enum {
        dry_run,
        repair,
    };

    pub const ReconcileReport = struct {
        sessions_checked: usize = 0,
        in_sync: usize = 0,
        repaired: usize = 0,
        drifted: usize = 0,
        index_ahead: usize = 0,
    };

    const SessionIdent = struct {
        origin: []const u8,
        session_id: []const u8,
    };

    pub fn reconcile(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        mode: ReconcileMode,
    ) !ReconcileReport {
        var report: ReconcileReport = .{};
        const sessions = try self.collectKnownSessions(io, gpa);
        defer freeSessionIdents(gpa, sessions);

        for (sessions) |sess| {
            report.sessions_checked += 1;
            const outcome = try self.reconcileSession(io, gpa, mode, sess.origin, sess.session_id);
            switch (outcome) {
                .in_sync => report.in_sync += 1,
                .repaired => report.repaired += 1,
                .drifted => report.drifted += 1,
                .index_ahead => report.index_ahead += 1,
            }
        }
        return report;
    }

    const SessionOutcome = enum {
        in_sync,
        repaired,
        drifted,
        index_ahead,
    };

    fn reconcileSession(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        mode: ReconcileMode,
        origin: []const u8,
        session_id: []const u8,
    ) !SessionOutcome {
        const path = try ref.buildRefPath(gpa, origin, session_id);
        defer gpa.free(path);
        const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
        defer gpa.free(lock_path);

        const parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        if (parent_end > 0) {
            try self.root.createDirPath(io, path[0..parent_end]);
        }

        var lock = try file_lock.LockFile.acquire(io, self.root, lock_path, .{});
        defer lock.release(io);

        const ref_tip = try readRefAtPath(io, self.root, gpa, path);
        const meta_ref = try self.readMetaRefTip(gpa, origin, session_id);

        if (hashOptEq(ref_tip, meta_ref)) {
            if (ref_tip == null) return .in_sync;
            const tip_hex = ref_tip.?.toHex();
            if (try self.index.hasStep(&tip_hex)) return .in_sync;
            if (mode == .dry_run) return .drifted;
            if (!try self.replaySessionChain(io, gpa, origin, session_id, null, ref_tip.?)) {
                return .index_ahead;
            }
            return .repaired;
        }

        if (ref_tip == null and meta_ref != null) {
            return .index_ahead;
        }
        if (ref_tip == null) return .in_sync;

        const tip_hex = ref_tip.?.toHex();
        const tip_in_index = try self.index.hasStep(&tip_hex);
        if (!tip_in_index) {
            if (mode == .dry_run) return .drifted;
            if (!try self.replaySessionChain(io, gpa, origin, session_id, meta_ref, ref_tip.?)) {
                return .index_ahead;
            }
            return .repaired;
        }

        if (meta_ref == null) {
            if (mode == .dry_run) return .drifted;
            try self.updateSessionMeta(gpa, origin, session_id, ref_tip.?);
            return .repaired;
        }

        if (mode == .dry_run) return .index_ahead;
        return .index_ahead;
    }

    fn replaySessionChain(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        origin: []const u8,
        session_id: []const u8,
        stop_hash: ?Hash,
        tip_hash: Hash,
    ) !bool {
        var chain: std.ArrayList(Hash) = .empty;
        defer chain.deinit(gpa);

        var cursor: ?Hash = tip_hash;
        var reached_stop = stop_hash == null;
        while (cursor) |h| {
            if (stop_hash) |stop| {
                if (h.eql(stop)) {
                    reached_stop = true;
                    break;
                }
            }

            try chain.append(gpa, h);

            var parsed = self.readStep(io, gpa, h) catch {
                return false;
            };
            defer parsed.deinit();
            cursor = if (parsed.value.parent) |parent_hex| try Hash.fromHex(parent_hex) else null;
        }

        if (stop_hash != null and !reached_stop) {
            return false;
        }

        try self.index.db.transaction();
        errdefer self.index.db.rollback();

        var i = chain.items.len;
        while (i > 0) : (i -= 1) {
            const h = chain.items[i - 1];
            const hex = h.toHex();
            var parsed = self.readStep(io, gpa, h) catch {
                return false;
            };
            defer parsed.deinit();
            const step = parsed.value;
            try self.index.insertStep(
                &hex,
                step.origin,
                step.session_id,
                step.turn_id,
                step.parent,
                step.tree,
                step.timestamp,
            );
            for (step.messages, 0..) |msg, seq| {
                try self.index.insertMessage(&hex, @intCast(seq), msg.role, msg.content);
            }
            for (step.tool_calls, 0..) |tc, seq| {
                try self.index.insertToolCall(&hex, @intCast(seq), tc.tool_name, tc.args, tc.result);
            }
        }

        const tip_hex = tip_hash.toHex();
        try self.index.upsertSession(origin, session_id, &tip_hex);
        try self.updateSessionMetaLocked(gpa, origin, session_id, tip_hash);
        try self.index.db.commit();
        return true;
    }

    fn collectKnownSessions(self: *Store, io: std.Io, gpa: std.mem.Allocator) ![]const SessionIdent {
        var list: std.ArrayList(SessionIdent) = .empty;
        errdefer {
            for (list.items) |sess| {
                gpa.free(sess.origin);
                gpa.free(sess.session_id);
            }
            list.deinit(gpa);
        }
        var seen = std.StringHashMap(void).init(gpa);
        defer {
            var it = seen.keyIterator();
            while (it.next()) |k| gpa.free(k.*);
            seen.deinit();
        }

        const rows = try self.index.listSessions(gpa);
        defer freeSessionRows(gpa, rows);
        for (rows) |row| {
            try appendUniqueSession(gpa, &list, &seen, row.origin, row.session_id);
        }

        var refs_dir = self.root.openDir(io, "refs/sessions", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return list.toOwnedSlice(gpa),
            else => return err,
        };
        defer refs_dir.close(io);

        var walker = try refs_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const sep = std.mem.indexOfScalar(u8, entry.path, '/') orelse continue;
            const origin_hex = entry.path[0..sep];
            const session_hex = entry.path[sep + 1 ..];
            const origin = decodeHexAlloc(gpa, origin_hex) catch continue;
            errdefer gpa.free(origin);
            const sess_id = decodeHexAlloc(gpa, session_hex) catch {
                gpa.free(origin);
                continue;
            };
            errdefer gpa.free(sess_id);
            try appendUniqueSessionOwned(gpa, &list, &seen, origin, sess_id);
        }

        return list.toOwnedSlice(gpa);
    }

    fn appendUniqueSession(
        gpa: std.mem.Allocator,
        list: *std.ArrayList(SessionIdent),
        seen: *std.StringHashMap(void),
        origin: []const u8,
        session_id: []const u8,
    ) !void {
        const origin_dup = try gpa.dupe(u8, origin);
        errdefer gpa.free(origin_dup);
        const sess_dup = try gpa.dupe(u8, session_id);
        errdefer gpa.free(sess_dup);
        try appendUniqueSessionOwned(gpa, list, seen, origin_dup, sess_dup);
    }

    fn appendUniqueSessionOwned(
        gpa: std.mem.Allocator,
        list: *std.ArrayList(SessionIdent),
        seen: *std.StringHashMap(void),
        origin_owned: []u8,
        session_owned: []u8,
    ) !void {
        const key = try std.fmt.allocPrint(gpa, "{x}:{x}", .{ origin_owned, session_owned });
        if (seen.contains(key)) {
            gpa.free(key);
            gpa.free(origin_owned);
            gpa.free(session_owned);
            return;
        }
        try seen.put(key, {});
        try list.append(gpa, .{
            .origin = origin_owned,
            .session_id = session_owned,
        });
    }

    fn decodeHexAlloc(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
        if (hex.len == 0 or (hex.len % 2) != 0) return error.InvalidRefPath;
        const out = try gpa.alloc(u8, hex.len / 2);
        errdefer gpa.free(out);
        _ = try std.fmt.hexToBytes(out, hex);
        return out;
    }

    fn freeSessionIdents(gpa: std.mem.Allocator, rows: []const SessionIdent) void {
        for (rows) |row| {
            gpa.free(row.origin);
            gpa.free(row.session_id);
        }
        gpa.free(rows);
    }

    fn readRefAtPath(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator, path: []const u8) !?Hash {
        const data = root.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer gpa.free(data);
        const trimmed = std.mem.trim(u8, data, " \r\n");
        return try Hash.fromHex(trimmed);
    }

    fn hashOptEq(a: ?Hash, b: ?Hash) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.eql(b.?);
    }

    fn metaKeyAlloc(gpa: std.mem.Allocator, origin: []const u8, session_id: []const u8, field: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "session::{x}:{x}::{s}", .{ origin, session_id, field });
    }

    fn readMetaRefTip(
        self: *Store,
        gpa: std.mem.Allocator,
        origin: []const u8,
        session_id: []const u8,
    ) !?Hash {
        const key = try metaKeyAlloc(gpa, origin, session_id, "last_ref_hash");
        defer gpa.free(key);
        const value = try self.index.metaGet(gpa, key);
        defer if (value) |v| gpa.free(v);
        if (value == null) return null;
        return Hash.fromHex(value.?) catch null;
    }

    fn updateSessionMeta(
        self: *Store,
        gpa: std.mem.Allocator,
        origin: []const u8,
        session_id: []const u8,
        tip_hash: Hash,
    ) !void {
        try self.index.db.transaction();
        errdefer self.index.db.rollback();
        try self.updateSessionMetaLocked(gpa, origin, session_id, tip_hash);
        try self.index.db.commit();
    }

    fn updateSessionMetaLocked(
        self: *Store,
        gpa: std.mem.Allocator,
        origin: []const u8,
        session_id: []const u8,
        tip_hash: Hash,
    ) !void {
        const tip_hex = tip_hash.toHex();
        const count = try self.index.countSessionSteps(origin, session_id);
        var seq_buf: [32]u8 = undefined;
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{count});

        const ref_key = try metaKeyAlloc(gpa, origin, session_id, "last_ref_hash");
        defer gpa.free(ref_key);
        const step_key = try metaKeyAlloc(gpa, origin, session_id, "last_step_hash");
        defer gpa.free(step_key);
        const seq_key = try metaKeyAlloc(gpa, origin, session_id, "last_step_seq");
        defer gpa.free(seq_key);

        try self.index.metaSet(ref_key, &tip_hex);
        try self.index.metaSet(step_key, &tip_hex);
        try self.index.metaSet(seq_key, seq_str);
    }

    pub const FinalizeCommitInput = struct {
        origin: []const u8,
        session_id: []const u8,
        turn_id: []const u8,
        tree_hash: []const u8,
        timestamp: i64,
        causes: []const Cause,
        messages: []const StepMessage,
        tool_calls: []const StepToolCall,
        expected_parent: ?Hash,
        retry_delta: i64 = 0,
    };

    pub const FinalizeCommitResult = union(enum) {
        committed: Hash,
        parent_moved: ?Hash,
        duplicate_turn: [64]u8,
    };

    pub fn commitFinalizedStep(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        input: FinalizeCommitInput,
    ) !FinalizeCommitResult {
        const path = try ref.buildRefPath(gpa, input.origin, input.session_id);
        defer gpa.free(path);

        const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{path});
        defer gpa.free(lock_path);

        const ref_parent_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        if (ref_parent_end > 0) {
            try self.root.createDirPath(io, path[0..ref_parent_end]);
        }

        var lock = try file_lock.LockFile.acquire(io, self.root, lock_path, .{});
        defer lock.release(io);

        const current_data = self.root.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (current_data) |d| gpa.free(d);

        const current: ?Hash = if (current_data) |d| blk: {
            const trimmed = std.mem.trim(u8, d, " \r\n");
            break :blk Hash.fromHex(trimmed) catch return error.CorruptRef;
        } else null;

        const matches = if (input.expected_parent) |exp|
            if (current) |cur| cur.eql(exp) else false
        else
            current == null;
        if (!matches) return .{ .parent_moved = current };

        if (try self.index.queryStepHash(input.origin, input.session_id, input.turn_id)) |existing_hex| {
            return .{ .duplicate_turn = existing_hex };
        }

        var parent_hex_buf: [64]u8 = undefined;
        const parent_str: ?[]const u8 = if (current) |h| blk: {
            parent_hex_buf = h.toHex();
            break :blk parent_hex_buf[0..];
        } else null;

        const step = Step{
            .parent = parent_str,
            .tree = input.tree_hash,
            .session_id = input.session_id,
            .origin = input.origin,
            .turn_id = input.turn_id,
            .causes = input.causes,
            .timestamp = input.timestamp,
            .messages = input.messages,
            .tool_calls = input.tool_calls,
        };
        const step_hash = try self.writeStep(io, gpa, step);
        const step_hex = step_hash.toHex();

        try self.index.db.transaction();
        errdefer self.index.db.rollback();

        try self.index.upsertSession(input.origin, input.session_id, &step_hex);
        try self.index.insertStep(
            &step_hex,
            input.origin,
            input.session_id,
            input.turn_id,
            parent_str,
            input.tree_hash,
            input.timestamp,
        );
        for (input.messages, 0..) |msg, i| {
            try self.index.insertMessage(&step_hex, @intCast(i), msg.role, msg.content);
        }
        for (input.tool_calls, 0..) |tc, i| {
            try self.index.insertToolCall(&step_hex, @intCast(i), tc.tool_name, tc.args, tc.result);
        }
        try self.updateSessionMetaLocked(gpa, input.origin, input.session_id, step_hash);
        if (input.retry_delta > 0) {
            try self.index.addMetaCounter(finalize_retries_metric_key, input.retry_delta);
        }
        try self.index.addMetaCounter(finalize_objects_metric_key, 1);

        try ref.writeRefToPath(io, self.root, path, step_hash);
        try self.index.db.commit();

        return .{ .committed = step_hash };
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
        messages: []const StepMessage,
        tool_calls: []const StepToolCall,
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

        const new_hex = new_hash.toHex();
        const new_hex_str: []const u8 = &new_hex;
        if (try self.index.queryStepHash(origin, session_id, step.turn_id)) |existing_hex| {
            if (!std.mem.eql(u8, &existing_hex, new_hex_str)) return false;
        }

        // Keep index rows, metadata updates, and the ref write in one lock window.
        try self.index.db.transaction();
        errdefer self.index.db.rollback();

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
        for (messages, 0..) |msg, i| {
            try self.index.insertMessage(new_hex_str, @intCast(i), msg.role, msg.content);
        }
        for (tool_calls, 0..) |tc, i| {
            try self.index.insertToolCall(new_hex_str, @intCast(i), tc.tool_name, tc.args, tc.result);
        }
        try self.updateSessionMetaLocked(gpa, origin, session_id, new_hash);

        // Write the new ref atomically (still under lock).
        try ref.writeRefToPath(io, self.root, path, new_hash);

        try self.index.db.commit();

        return true;
    }
};

fn countObjectFiles(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir) !usize {
    var obj_dir = root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        else => return err,
    };
    defer obj_dir.close(io);

    var walker = try obj_dir.walk(gpa);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) count += 1;
    }
    return count;
}

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
    const ok = try s.casRef(io, std.testing.allocator, "github.com/u/r", "sess-1", null, h1, &step1, step1.messages, step1.tool_calls);
    try std.testing.expect(ok);

    // Verify ref.
    const head = try s.readRef(io, std.testing.allocator, "github.com/u/r", "sess-1");
    try std.testing.expect(head != null);
    try std.testing.expect(h1.eql(head.?));
}

test "store casRef refuses duplicate turn id with different hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try Store.open(io, tmp.dir, gpa);
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
    const h1 = try s.writeStep(io, gpa, step1);
    try std.testing.expect(try s.casRef(io, gpa, step1.origin, step1.session_id, null, h1, &step1, step1.messages, step1.tool_calls));

    var h1_hex = h1.toHex();
    const existing = try s.index.queryStepHash(step1.origin, step1.session_id, step1.turn_id);
    try std.testing.expect(existing != null);
    try std.testing.expectEqualStrings(&h1_hex, &existing.?);

    const step2 = Step{
        .parent = &h1_hex,
        .tree = "b" ** 64,
        .session_id = "sess-1",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1001,
    };
    const h2 = try s.writeStep(io, gpa, step2);
    try std.testing.expect(!try s.casRef(io, gpa, step2.origin, step2.session_id, h1, h2, &step2, step2.messages, step2.tool_calls));

    const head = try s.readRef(io, gpa, step1.origin, step1.session_id);
    try std.testing.expect(head != null);
    try std.testing.expect(h1.eql(head.?));
}

test "commitFinalizedStep retries without rewriting step object" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const step1 = Step{
        .parent = null,
        .tree = "a" ** 64,
        .session_id = "sess-r",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };
    const h1 = try s.writeStep(io, gpa, step1);
    try std.testing.expect(try s.casRef(io, gpa, step1.origin, step1.session_id, null, h1, &step1, step1.messages, step1.tool_calls));

    const before_count = try countObjectFiles(io, gpa, s.root);

    const first_try = try s.commitFinalizedStep(io, gpa, .{
        .origin = step1.origin,
        .session_id = step1.session_id,
        .turn_id = "t2",
        .tree_hash = "b" ** 64,
        .timestamp = 1001,
        .causes = &.{},
        .messages = &.{.{ .role = "assistant", .content = "hello" }},
        .tool_calls = &.{},
        .expected_parent = null,
    });
    try std.testing.expect(first_try == .parent_moved);
    try std.testing.expect(first_try.parent_moved != null);

    const wrong_parent = Hash.ofBytes("wrong-parent");
    const second_try = try s.commitFinalizedStep(io, gpa, .{
        .origin = step1.origin,
        .session_id = step1.session_id,
        .turn_id = "t2",
        .tree_hash = "b" ** 64,
        .timestamp = 1001,
        .causes = &.{},
        .messages = &.{.{ .role = "assistant", .content = "hello" }},
        .tool_calls = &.{},
        .expected_parent = wrong_parent,
    });
    try std.testing.expect(second_try == .parent_moved);

    const third_try = try s.commitFinalizedStep(io, gpa, .{
        .origin = step1.origin,
        .session_id = step1.session_id,
        .turn_id = "t2",
        .tree_hash = "b" ** 64,
        .timestamp = 1001,
        .causes = &.{},
        .messages = &.{.{ .role = "assistant", .content = "hello" }},
        .tool_calls = &.{},
        .expected_parent = h1,
        .retry_delta = 2,
    });
    try std.testing.expect(third_try == .committed);

    const after_count = try countObjectFiles(io, gpa, s.root);
    try std.testing.expectEqual(before_count + 1, after_count);

    const retries = try s.index.readMetaCounter(finalize_retries_metric_key);
    const objects = try s.index.readMetaCounter(finalize_objects_metric_key);
    try std.testing.expectEqual(@as(i64, 2), retries);
    try std.testing.expectEqual(@as(i64, 1), objects);
}

test "reconcile repairs when ref is ahead of index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const step = Step{
        .parent = null,
        .tree = "a" ** 64,
        .session_id = "sess-r1",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };
    const h = try s.writeStep(io, gpa, step);
    try std.testing.expect(try s.casRef(io, gpa, step.origin, step.session_id, null, h, &step, step.messages, step.tool_calls));

    const h_hex = h.toHex();
    try s.index.db.exec("delete from messages where step_hash=?", .{&h_hex});
    try s.index.db.exec("delete from tool_calls where step_hash=?", .{&h_hex});
    try s.index.db.exec("delete from steps where hash=?", .{&h_hex});

    const before = try s.reconcile(io, gpa, .dry_run);
    try std.testing.expectEqual(@as(usize, 1), before.drifted + before.index_ahead);

    const repaired = try s.reconcile(io, gpa, .repair);
    try std.testing.expectEqual(@as(usize, 1), repaired.repaired);

    const step_hex = h.toHex();
    try std.testing.expect(try s.index.hasStep(&step_hex));
}

test "reconcile reports index ahead of ref without mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const step = Step{
        .parent = null,
        .tree = "b" ** 64,
        .session_id = "sess-r2",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1001,
    };
    const h = try s.writeStep(io, gpa, step);
    try std.testing.expect(try s.casRef(io, gpa, step.origin, step.session_id, null, h, &step, step.messages, step.tool_calls));

    const ref_path = try ref.buildRefPath(gpa, step.origin, step.session_id);
    defer gpa.free(ref_path);
    try s.root.deleteFile(io, ref_path);

    const report = try s.reconcile(io, gpa, .dry_run);
    try std.testing.expectEqual(@as(usize, 1), report.index_ahead);
    try std.testing.expectEqual(@as(usize, 0), report.repaired);

    const step_hex = h.toHex();
    try std.testing.expect(try s.index.hasStep(&step_hex));
}

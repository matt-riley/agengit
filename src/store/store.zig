const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");
const pack_mod = @import("pack.zig");
const ref = @import("ref.zig");
const index_mod = @import("index.zig");
const file_lock = @import("../util/file_lock.zig");
const ignore_mod = @import("ignore.zig");
const outcome_mod = @import("outcome.zig");
const snapshot_mod = @import("snapshot.zig");
const blame_mod = @import("blame.zig");
const zqlite = @import("zqlite");
const blame_recorder_mod = @import("blame_recorder.zig");
const reconcile_mod = @import("reconcile.zig");
const audit_mod = @import("audit.zig");
const preview_mod = @import("preview.zig");

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
pub const TimelineRow = index_mod.TimelineRow;
pub const TimelineOptions = index_mod.TimelineOptions;
pub const freeSessionRows = index_mod.freeSessionRows;
pub const freeStepRows = index_mod.freeStepRows;
pub const freeSessionRow = index_mod.freeSessionRow;
pub const freeStepRow = index_mod.freeStepRow;
pub const freeTimelineRows = index_mod.freeTimelineRows;
pub const freeTimelineRow = index_mod.freeTimelineRow;
pub const Ignorer = ignore_mod.Ignorer;
pub const SnapshotConfig = snapshot_mod.SnapshotConfig;
pub const BlameMap = blame_mod.BlameMap;
pub const BlameEntry = blame_mod.BlameEntry;
pub const Outcome = outcome_mod.Outcome;
pub const freeBlameMap = blame_mod.freeBlameMap;
pub const computeBlame = blame_mod.computeBlame;
pub const finalize_retries_metric_key = "metrics.finalize_retries_total";
pub const finalize_objects_metric_key = "metrics.finalize_objects_written_total";
pub const blame_needs_reindex_key = "blame.needs_reindex";
pub const blame_last_timestamp_key = "blame.last_step_timestamp";

/// Upper bound on changed files blamed in a single finalize.  Exceeding it marks
/// blame as needing a reindex instead of spiking finalize latency (e.g. the
/// first finalize in a large pre-existing repo).  `0` means unbounded (reindex).
pub const blame_max_changed_files: usize = 5000;

/// The agit content-addressed object store and associated index.
///
/// The store lives inside a `.agit/` directory that is a child of the
/// repository root.  Call `open` to open or create it.
pub const Store = struct {
    root: std.Io.Dir, // the .agit/ dir; closed by deinit
    index: Index,

    pub const OpenOptions = struct {
        reconcile: bool = true,
    };

    /// Open (or create) the store rooted at `repo_dir/.agit/`.
    pub fn open(io: std.Io, repo_dir: std.Io.Dir, gpa: std.mem.Allocator) !Store {
        return openWithOptions(io, repo_dir, gpa, .{});
    }

    /// Open an existing store rooted at `repo_dir/.agit/` without creating
    /// missing directories or running reconcile side effects.
    pub fn openExisting(io: std.Io, repo_dir: std.Io.Dir, gpa: std.mem.Allocator) !Store {
        _ = gpa;
        var root = try repo_dir.openDir(io, ".agit", .{});
        errdefer root.close(io);

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try root.realPath(io, &path_buf);
        var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
        const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

        const idx = try Index.open(db_path);
        errdefer idx.close();
        try idx.migrate();

        return .{ .root = root, .index = idx };
    }

    pub fn openWithOptions(io: std.Io, repo_dir: std.Io.Dir, gpa: std.mem.Allocator, options: OpenOptions) !Store {
        // Ensure .agit/ and its subdirectories exist.
        try repo_dir.createDirPath(io, ".agit/objects");
        try repo_dir.createDirPath(io, ".agit/objects/pack");
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

        // Fresh stores can be opened by several hooks at once. Serialize index
        // creation and first-open maintenance so fail-open hooks do not race on
        // migrations or bootstrap metadata writes.
        var init_lock = try file_lock.LockFile.acquire(io, root, "index-init.lock", .{});
        defer init_lock.release(io);

        const idx = try Index.open(db_path);
        errdefer idx.close();

        try idx.migrate();
        var store = Store{ .root = root, .index = idx };
        errdefer store.deinit(io);

        try store.ensureObjectIndexState(io, gpa);
        if (options.reconcile) {
            _ = try store.reconcile(io, gpa, .repair);
        }
        return store;
    }

    pub fn deinit(self: *Store, io: std.Io) void {
        self.index.close();
        self.root.close(io);
        self.* = undefined;
    }

    /// Walk up from `start_dir` looking for a `.agit/` directory and open the
    /// existing store without creating or reconciling mutable store paths.
    ///
    /// Returns `error.StoreNotFound` if none is found.
    pub fn findAndOpen(io: std.Io, start_dir: std.Io.Dir, gpa: std.mem.Allocator) !Store {
        var repo_dir = try Store.findRoot(io, start_dir);
        defer repo_dir.close(io);
        return Store.openExisting(io, repo_dir, gpa);
    }

    pub fn findRoot(io: std.Io, start_dir: std.Io.Dir) !std.Io.Dir {
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
                return current;
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
        const written = try object.writeDetailed(io, self.root, data);
        const hex = written.hash.toHex();
        try self.index.insertObject(&hex, "blob", written.size);
        return written.hash;
    }

    /// Write a Tree object. Returns its hash.
    pub fn writeTree(self: *Store, io: std.Io, gpa: std.mem.Allocator, tree: Tree) !Hash {
        const written = try object.writeTreeDetailed(io, self.root, gpa, tree);
        const hex = written.hash.toHex();
        try self.index.insertObject(&hex, "tree", written.size);
        return written.hash;
    }

    /// Write a Step object. Returns its hash.
    pub fn writeStep(self: *Store, io: std.Io, gpa: std.mem.Allocator, step: Step) !Hash {
        const written = try object.writeStepDetailed(io, self.root, gpa, step);
        const hex = written.hash.toHex();
        try self.index.insertObject(&hex, "step", written.size);
        return written.hash;
    }

    // ── Object reads ─────────────────────────────────────────────────────────

    /// Read raw bytes for the object identified by `h`. Caller owns result.
    pub fn readBlob(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) ![]u8 {
        return object.read(io, self.root, gpa, h) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                const hex = h.toHex();
                if (try self.index.lookupPackedObject(gpa, &hex)) |packed_row| {
                    var packed_entry = packed_row;
                    defer packed_entry.deinit(gpa);
                    return pack_mod.readObject(io, self.root, gpa, packed_entry.pack_name, packed_entry.offset);
                }
                if (try pack_mod.readObjectByHash(io, self.root, gpa, h)) |packed_result| {
                    const found = packed_result;
                    gpa.free(found.pack_name);
                    return found.raw;
                }
                return err;
            },
            else => return err,
        };
    }

    /// Read and deserialize a Tree object. Caller must call `.deinit()`.
    pub fn readTree(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(Tree) {
        const data = try self.readBlob(io, gpa, h);
        defer gpa.free(data);
        return std.json.parseFromSlice(Tree, gpa, data, .{ .allocate = .alloc_always });
    }

    /// Read and deserialize a Step object. Caller must call `.deinit()`.
    pub fn readStep(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(Step) {
        const data = try self.readBlob(io, gpa, h);
        defer gpa.free(data);
        return std.json.parseFromSlice(Step, gpa, data, .{ .allocate = .alloc_always });
    }

    /// Resolve a hex prefix to object candidates.
    pub fn resolvePrefix(self: *Store, io: std.Io, gpa: std.mem.Allocator, prefix: []const u8) !object.PrefixResolution {
        if (try self.shouldUseObjectIndex()) {
            const matches = self.index.lookupObjectPrefix(prefix) catch {
                const loose = try object.resolvePrefixDetailed(io, self.root, gpa, prefix);
                const packed_matches = try pack_mod.lookupPrefix(io, self.root, gpa, prefix);
                return mergePrefixResolution(loose, packed_matches);
            };
            return switch (matches.count) {
                0 => .not_found,
                1 => .{ .unique = try Hash.fromHex(&matches.hashes[0]) },
                else => .{
                    .ambiguous = .{
                        try Hash.fromHex(&matches.hashes[0]),
                        try Hash.fromHex(&matches.hashes[1]),
                    },
                },
            };
        }
        return object.resolvePrefixDetailed(io, self.root, gpa, prefix);
    }

    pub const ObjectIndexAudit = struct {
        indexed_complete: bool,
        disk_count: usize,
        indexed_count: usize,
        missing_rows: usize,
    };

    pub fn auditObjectIndex(self: *Store, io: std.Io, gpa: std.mem.Allocator) !ObjectIndexAudit {
        return audit_mod.auditObjectIndex(self, io, gpa);
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
        return snapshot_mod.snapshot(io, repo_dir, gpa, self.root, &self.index, ignorer, config);
    }

    // ── Blame ─────────────────────────────────────────────────────────────────

    /// Write a BlameMap to the object store.  Returns its hash.
    pub fn writeBlame(self: *Store, io: std.Io, gpa: std.mem.Allocator, bm: BlameMap) !Hash {
        const written = try blame_mod.writeBlameDetailed(io, self.root, gpa, bm);
        const hex = written.hash.toHex();
        try self.index.insertObject(&hex, "blame", written.size);
        return written.hash;
    }

    /// Read a BlameMap from the object store.  Caller calls `parsed.deinit()`.
    pub fn readBlame(self: *Store, io: std.Io, gpa: std.mem.Allocator, h: Hash) !std.json.Parsed(BlameMap) {
        const data = try self.readBlob(io, gpa, h);
        defer gpa.free(data);
        return std.json.parseFromSlice(BlameMap, gpa, data, .{ .allocate = .alloc_always });
    }

    // ── Blame recording ─────────────────────────────────────────────────────

    pub fn blameNeedsReindex(self: *Store) !bool {
        return (try self.index.readMetaCounter(blame_needs_reindex_key)) != 0;
    }

    pub fn setBlameNeedsReindex(self: *Store, value: bool) !void {
        if (value) {
            try self.index.metaSet(blame_needs_reindex_key, "1");
        } else {
            try self.index.metaDelete(blame_needs_reindex_key);
        }
    }

    /// Return a strictly-increasing finalize timestamp.  Finalizes are serialized
    /// by `gc.lock`, so advancing this global counter yields a canonical total
    /// order across all sessions that `agit reindex` reproduces by sorting steps
    /// on `timestamp`.  Call `advanceBlameTimestamp` after the step commits.
    pub fn monotonicTimestamp(self: *Store, now_ms: i64) !i64 {
        const last = try self.index.readMetaCounter(blame_last_timestamp_key);
        return if (now_ms > last) now_ms else last + 1;
    }

    pub fn advanceBlameTimestamp(self: *Store, timestamp: i64) !void {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{timestamp});
        try self.index.metaSet(blame_last_timestamp_key, str);
    }

    pub const StepBlameInput = struct {
        step_hash: []const u8, // 64 hex
        tree_hash: []const u8, // 64 hex
        session_origin: []const u8,
        session_id: []const u8,
        timestamp: i64,
        max_file_bytes: u64 = 16 * 1024 * 1024,
        /// `0` disables the changed-file guard (used by reindex).
        max_changed_files: usize = blame_max_changed_files,
    };

    /// Compute and persist incremental blame for every changed text file in the
    /// given step's tree.  Blame objects are written content-addressed; the
    /// per-step `blame_maps` rows are inserted in a single transaction so a
    /// failure leaves no partial linkage.  Shared by finalize and reindex.
    pub fn recordStepBlame(self: *Store, io: std.Io, gpa: std.mem.Allocator, input: StepBlameInput) !void {
        return blame_recorder_mod.recordStepBlame(self, io, gpa, input);
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

    pub fn reconcile(
        self: *Store,
        io: std.Io,
        gpa: std.mem.Allocator,
        mode: ReconcileMode,
    ) !ReconcileReport {
        return reconcile_mod.reconcile(self, io, gpa, mode);
    }

    fn metaKeyAlloc(gpa: std.mem.Allocator, origin: []const u8, session_id: []const u8, field: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "session::{x}:{x}::{s}", .{ origin, session_id, field });
    }

    pub fn readMetaRefTip(
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

    pub fn updateSessionMeta(
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

    pub fn updateSessionMetaLocked(
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
        outcome: ?[]const u8 = null,
        expected_parent: ?Hash,
        retry_delta: i64 = 0,
        git_commit: ?[]const u8 = null,
        git_branch: ?[]const u8 = null,
        git_dirty: ?bool = null,
        model: ?[]const u8 = null,
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
            .model = input.model,
            .turn_id = input.turn_id,
            .causes = input.causes,
            .timestamp = input.timestamp,
            .messages = input.messages,
            .tool_calls = input.tool_calls,
            .outcome = input.outcome,
            .git_commit = input.git_commit,
            .git_branch = input.git_branch,
            .git_dirty = input.git_dirty,
        };
        const step_write = try object.writeStepDetailed(io, self.root, gpa, step);
        const step_hash = step_write.hash;
        const step_hex = step_hash.toHex();

        try self.index.db.transaction();
        errdefer self.index.db.rollback();

        try self.index.insertObject(&step_hex, "step", step_write.size);
        try self.index.upsertSession(input.origin, input.session_id, &step_hex);
        const preview_str = try preview_mod.computePreviewAlloc(gpa, step);
        defer gpa.free(preview_str);
        try self.index.insertStep(
            &step_hex,
            input.origin,
            input.session_id,
            input.turn_id,
            parent_str,
            input.tree_hash,
            input.timestamp,
            input.model,
            input.outcome,
            input.git_commit,
            input.git_branch,
            input.git_dirty,
            preview_str,
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

    fn ensureObjectIndexState(self: *Store, io: std.Io, gpa: std.mem.Allocator) !void {
        return audit_mod.ensureObjectIndexState(self, io, gpa);
    }

    fn shouldUseObjectIndex(self: *Store) !bool {
        return (try self.index.getObjectsComplete()) orelse false;
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

        const preview_str = try preview_mod.computePreviewAlloc(gpa, step.*);
        defer gpa.free(preview_str);

        const parent_hex_buf = if (step.parent) |p| p else null;
        try self.index.insertStep(
            new_hex_str,
            origin,
            session_id,
            step.turn_id,
            parent_hex_buf,
            step.tree,
            step.timestamp,
            step.model,
            step.outcome,
            step.git_commit,
            step.git_branch,
            step.git_dirty,
            preview_str,
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

pub fn countObjectFiles(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir) !usize {
    var obj_dir = root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        else => return err,
    };
    defer obj_dir.close(io);

    var walker = try obj_dir.walk(gpa);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path.len != 65 or entry.path[2] != '/') continue;
        count += 1;
    }
    return count;
}

fn mergePrefixResolution(loose: object.PrefixResolution, packed_matches: pack_mod.PrefixMatches) object.PrefixResolution {
    var current = loose;
    var i: usize = 0;
    while (i < @min(packed_matches.count, packed_matches.hashes.len)) : (i += 1) {
        const candidate = packed_matches.hashes[i];
        switch (current) {
            .not_found => current = .{ .unique = candidate },
            .unique => |existing| {
                if (!existing.eql(candidate)) {
                    current = .{ .ambiguous = .{ existing, candidate } };
                    return current;
                }
            },
            .ambiguous => return current,
        }
    }
    if (packed_matches.count > packed_matches.hashes.len) {
        return switch (current) {
            .not_found => .{ .ambiguous = .{ packed_matches.hashes[0], packed_matches.hashes[1] } },
            .unique => |existing| .{ .ambiguous = .{ existing, packed_matches.hashes[0] } },
            .ambiguous => current,
        };
    }
    return current;
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

test "reconcile repairs stale meta_ref when ref_tip is already indexed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const step = Step{
        .parent = null,
        .tree = "c" ** 64,
        .session_id = "sess-r3",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1002,
    };
    const h = try s.writeStep(io, gpa, step);
    try std.testing.expect(try s.casRef(io, gpa, step.origin, step.session_id, null, h, &step, step.messages, step.tool_calls));

    // Corrupt meta_ref so it diverges from the ref file while the tip is indexed.
    // Key format mirrors metaKeyAlloc: "session::{hex(origin)}:{hex(session_id)}::{field}"
    const wrong_key = try std.fmt.allocPrint(gpa, "session::{x}:{x}::last_ref_hash", .{ step.origin, step.session_id });
    defer gpa.free(wrong_key);
    try s.index.metaSet(wrong_key, &("ff" ** 32).*);

    const dry = try s.reconcile(io, gpa, .dry_run);
    try std.testing.expectEqual(@as(usize, 1), dry.drifted);

    const repaired = try s.reconcile(io, gpa, .repair);
    try std.testing.expectEqual(@as(usize, 1), repaired.repaired);

    // After repair meta_ref must match the ref file.
    const meta_tip = try s.readMetaRefTip(gpa, step.origin, step.session_id);
    try std.testing.expect(meta_tip != null);
    try std.testing.expect(h.eql(meta_tip.?));
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

fn removeObjectFile(root: std.Io.Dir, io: std.Io, hash_hex: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "objects/{s}/{s}", .{ hash_hex[0..2], hash_hex[2..] });
    try root.deleteFile(io, path);
}

test "recordStepBlame still computes incremental blame when prior state exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const blob1 = try s.writeBlob(io, "line one\nline two\n");
    const tree1 = Tree{ .entries = &.{
        .{ .path = "src/file.txt", .blob = &blob1.toHex(), .mode = "file", .size = 18 },
    } };
    const tree1_hash = try s.writeTree(io, gpa, tree1);

    const step1 = Step{
        .parent = null,
        .tree = &tree1_hash.toHex(),
        .session_id = "blame-ok",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };
    const h1 = try s.writeStep(io, gpa, step1);
    try std.testing.expect(try s.casRef(io, gpa, step1.origin, step1.session_id, null, h1, &step1, step1.messages, step1.tool_calls));

    const h1_hex = h1.toHex();
    try s.recordStepBlame(io, gpa, .{
        .step_hash = &h1_hex,
        .tree_hash = &tree1_hash.toHex(),
        .session_origin = step1.origin,
        .session_id = step1.session_id,
        .timestamp = step1.timestamp,
    });

    const first = try s.index.queryLatestBlame("src/file.txt");
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings(&h1_hex, &first.?.step_hash);

    const blob2 = try s.writeBlob(io, "line one\nchanged two\n");
    const tree2 = Tree{ .entries = &.{
        .{ .path = "src/file.txt", .blob = &blob2.toHex(), .mode = "file", .size = 21 },
    } };
    const tree2_hash = try s.writeTree(io, gpa, tree2);

    const step2 = Step{
        .parent = &h1_hex,
        .tree = &tree2_hash.toHex(),
        .session_id = "blame-ok",
        .origin = "github.com/u/r",
        .turn_id = "t2",
        .causes = &.{},
        .timestamp = 1001,
    };
    const h2 = try s.writeStep(io, gpa, step2);
    try std.testing.expect(try s.casRef(io, gpa, step2.origin, step2.session_id, h1, h2, &step2, step2.messages, step2.tool_calls));

    const h2_hex = h2.toHex();
    try s.recordStepBlame(io, gpa, .{
        .step_hash = &h2_hex,
        .tree_hash = &tree2_hash.toHex(),
        .session_origin = step2.origin,
        .session_id = step2.session_id,
        .timestamp = step2.timestamp,
    });

    try std.testing.expect(!try s.blameNeedsReindex());
    const latest = try s.index.queryLatestBlame("src/file.txt");
    try std.testing.expect(latest != null);
    try std.testing.expectEqualStrings(&h2_hex, &latest.?.step_hash);
}

test "recordStepBlame marks reindex when prior blame object is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var s = try Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const blob1 = try s.writeBlob(io, "line one\nline two\n");
    const tree1 = Tree{ .entries = &.{
        .{ .path = "src/file.txt", .blob = &blob1.toHex(), .mode = "file", .size = 18 },
    } };
    const tree1_hash = try s.writeTree(io, gpa, tree1);

    const step1 = Step{
        .parent = null,
        .tree = &tree1_hash.toHex(),
        .session_id = "blame-missing",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };
    const h1 = try s.writeStep(io, gpa, step1);
    try std.testing.expect(try s.casRef(io, gpa, step1.origin, step1.session_id, null, h1, &step1, step1.messages, step1.tool_calls));

    const h1_hex = h1.toHex();
    try s.recordStepBlame(io, gpa, .{
        .step_hash = &h1_hex,
        .tree_hash = &tree1_hash.toHex(),
        .session_origin = step1.origin,
        .session_id = step1.session_id,
        .timestamp = step1.timestamp,
    });

    const before = try s.index.queryLatestBlame("src/file.txt");
    try std.testing.expect(before != null);
    const blame_hex = before.?.blame_hash;

    // Remove the prior blame object so the second step cannot load it.
    try removeObjectFile(s.root, io, &blame_hex);

    const blob2 = try s.writeBlob(io, "line one\nchanged two\n");
    const tree2 = Tree{ .entries = &.{
        .{ .path = "src/file.txt", .blob = &blob2.toHex(), .mode = "file", .size = 21 },
    } };
    const tree2_hash = try s.writeTree(io, gpa, tree2);

    const step2 = Step{
        .parent = &h1_hex,
        .tree = &tree2_hash.toHex(),
        .session_id = "blame-missing",
        .origin = "github.com/u/r",
        .turn_id = "t2",
        .causes = &.{},
        .timestamp = 1001,
    };
    const h2 = try s.writeStep(io, gpa, step2);
    try std.testing.expect(try s.casRef(io, gpa, step2.origin, step2.session_id, h1, h2, &step2, step2.messages, step2.tool_calls));

    const h2_hex = h2.toHex();
    var failed = false;
    s.recordStepBlame(io, gpa, .{
        .step_hash = &h2_hex,
        .tree_hash = &tree2_hash.toHex(),
        .session_origin = step2.origin,
        .session_id = step2.session_id,
        .timestamp = step2.timestamp,
    }) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        failed = true;
    };
    try std.testing.expect(failed);
    try std.testing.expect(try s.blameNeedsReindex());

    const after = try s.index.queryLatestBlame("src/file.txt");
    try std.testing.expect(after != null);
    try std.testing.expectEqualStrings(&h1_hex, &after.?.step_hash);
}

test "store write and read tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var s = try Store.open(io, tmp.dir, std.testing.allocator);
    defer s.deinit(io);

    const blob_data = "tree leaf content";
    const blob_h = try s.writeBlob(io, blob_data);
    const blob_hex = blob_h.toHex();

    const tree = Tree{
        .entries = &.{
            .{
                .path = "hello.txt",
                .blob = &blob_hex,
                .mode = "100644",
                .size = blob_data.len,
            },
        },
    };
    const h = try s.writeTree(io, std.testing.allocator, tree);
    var parsed = try s.readTree(io, std.testing.allocator, h);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try std.testing.expectEqualStrings("hello.txt", parsed.value.entries[0].path);
    try std.testing.expectEqualStrings(&blob_hex, parsed.value.entries[0].blob);
    try std.testing.expectEqualStrings("100644", parsed.value.entries[0].mode);
    try std.testing.expectEqual(@as(u64, blob_data.len), parsed.value.entries[0].size);
}

test "store write and read step" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var s = try Store.open(io, tmp.dir, std.testing.allocator);
    defer s.deinit(io);

    const step = Step{
        .parent = null,
        .tree = "a" ** 64,
        .session_id = "sess-roundtrip",
        .origin = "test-origin",
        .turn_id = "turn-1",
        .causes = &.{},
        .timestamp = 1234567890,
        .messages = &.{},
        .tool_calls = &.{},
    };
    const h = try s.writeStep(io, std.testing.allocator, step);
    var parsed = try s.readStep(io, std.testing.allocator, h);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sess-roundtrip", parsed.value.session_id);
    try std.testing.expectEqualStrings("test-origin", parsed.value.origin);
    try std.testing.expectEqualStrings("turn-1", parsed.value.turn_id);
    try std.testing.expectEqual(@as(i64, 1234567890), parsed.value.timestamp);
    try std.testing.expectEqualStrings("a" ** 64, parsed.value.tree);
    try std.testing.expect(parsed.value.parent == null);
}

test "store resolvePrefix finds unique hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var s = try Store.open(io, tmp.dir, std.testing.allocator);
    defer s.deinit(io);

    const data = "unique content for prefix test";
    const hash = try s.writeBlob(io, data);
    const hex = hash.toHex();

    const resolved = try s.resolvePrefix(io, std.testing.allocator, &hex);
    try std.testing.expect(hash.eql(resolved.unique));
}

test "store resolvePrefix returns not_found for unknown prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var s = try Store.open(io, tmp.dir, std.testing.allocator);
    defer s.deinit(io);

    const resolved = try s.resolvePrefix(io, std.testing.allocator, "0000000000000000");
    try std.testing.expect(resolved == .not_found);
}

const std = @import("std");
const zqlite = @import("zqlite");

/// SQLite-backed index for fast session and step queries.
pub const Index = struct {
    db: zqlite.Conn,

    pub const current_schema_version: i64 = 12;
    pub const objects_complete_meta_key = "index.objects.complete";

    pub const ObjectPrefixMatches = struct {
        count: usize = 0,
        hashes: [2][64]u8 = undefined,
    };

    /// Open (or create) the index database at `db_path_z`.
    pub fn open(db_path_z: [:0]const u8) !Index {
        const flags = zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode;
        const db = try zqlite.open(db_path_z.ptr, flags);
        errdefer db.close();

        try db.busyTimeout(5_000);
        try db.execNoArgs("pragma journal_mode=wal");
        try db.execNoArgs("pragma foreign_keys=on");

        return .{ .db = db };
    }

    pub fn openReadOnly(gpa: std.mem.Allocator, db_path: []const u8) !Index {
        const uri_text = try std.fmt.allocPrint(gpa, "file:{s}?mode=ro", .{db_path});
        defer gpa.free(uri_text);
        const uri = try gpa.dupeZ(u8, uri_text);
        defer gpa.free(uri);

        const flags = zqlite.OpenFlags.ReadOnly | zqlite.OpenFlags.Uri | zqlite.OpenFlags.EXResCode;
        const db = try zqlite.open(uri, flags);
        errdefer db.close();
        try db.busyTimeout(5_000);
        return .{ .db = db };
    }

    pub fn close(self: Index) void {
        self.db.close();
    }

    /// Apply all pending schema migrations.
    pub fn migrate(self: Index) !void {
        try self.db.execNoArgs(
            \\create table if not exists schema_migrations (
            \\  version    integer primary key,
            \\  applied_at integer not null default (unixepoch())
            \\)
        );

        const current_version: i64 = blk: {
            const row = try self.db.row(
                "select coalesce(max(version), 0) from schema_migrations",
                .{},
            );
            if (row) |r| {
                defer r.deinit();
                break :blk r.get(i64, 0);
            }
            break :blk 0;
        };

        if (current_version < 1) {
            try self.applyMigration1();
        }
        if (current_version < 2) {
            try self.applyMigration2();
        }
        if (current_version < 3) {
            try self.applyMigration3();
        }
        if (current_version < 4) {
            try self.applyMigration4();
        }
        if (current_version < 5) {
            try self.applyMigration5();
        }
        if (current_version < 6) {
            try self.applyMigration6();
        }
        if (current_version < 7) {
            try self.applyMigration7();
        }
        if (current_version < 8) {
            try self.applyMigration8();
        }
        if (current_version < 9) {
            try self.applyMigration9();
        }
        if (current_version < 10) {
            try self.applyMigration10();
        }
        if (current_version < 11) {
            try self.applyMigration11();
        }
        if (current_version < 12) {
            try self.applyMigration12();
        }
    }

    fn applyMigration1(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs(
            \\create table sessions (
            \\  origin     text not null,
            \\  session_id text not null,
            \\  head_hash  text,
            \\  updated_at integer not null default (unixepoch()),
            \\  primary key (origin, session_id)
            \\)
        );

        try self.db.execNoArgs(
            \\create table steps (
            \\  hash           text primary key,
            \\  session_origin text not null,
            \\  session_id     text not null,
            \\  turn_id        text not null,
            \\  parent_hash    text,
            \\  tree_hash      text not null,
            \\  timestamp      integer not null,
            \\  foreign key (session_origin, session_id) references sessions (origin, session_id)
            \\)
        );

        try self.db.execNoArgs(
            \\create table messages (
            \\  id         integer primary key,
            \\  step_hash  text not null references steps (hash),
            \\  role       text not null,
            \\  content    text not null
            \\)
        );

        try self.db.execNoArgs(
            \\create table tool_calls (
            \\  id         integer primary key,
            \\  step_hash  text not null references steps (hash),
            \\  tool_name  text not null,
            \\  args       text not null,
            \\  result     text
            \\)
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 1)},
        );

        try self.db.commit();
    }

    fn applyMigration2(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        // Add sequence columns for deterministic ordering and idempotent inserts.
        try self.db.execNoArgs("alter table messages add column seq integer not null default 0");
        try self.db.execNoArgs("alter table tool_calls add column seq integer not null default 0");

        // Unique indices for idempotency.
        try self.db.execNoArgs(
            "create unique index messages_step_seq on messages(step_hash, seq)",
        );
        try self.db.execNoArgs(
            "create unique index tool_calls_step_seq on tool_calls(step_hash, seq)",
        );
        // Prevent duplicate turns for the same session.
        try self.db.execNoArgs(
            "create unique index steps_turn on steps(session_origin, session_id, turn_id)",
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 2)},
        );

        try self.db.commit();
    }

    fn applyMigration3(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs(
            "create index if not exists sessions_updated_at_desc on sessions(updated_at desc)",
        );
        try self.db.execNoArgs(
            "create index if not exists steps_session_timestamp on steps(session_origin, session_id, timestamp)",
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 3)},
        );

        try self.db.commit();
    }

    fn applyMigration4(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs(
            \\create table if not exists meta (
            \\  key   text primary key,
            \\  value text not null
            \\)
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 4)},
        );

        try self.db.execNoArgs("pragma user_version = 4");
        try self.db.commit();
    }

    fn applyMigration5(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs(
            \\create table if not exists objects (
            \\  hash       text primary key,
            \\  kind       text not null,
            \\  size       integer not null,
            \\  created_at integer not null default (unixepoch())
            \\)
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 5)},
        );

        try self.db.execNoArgs("pragma user_version = 5");
        try self.db.commit();
    }

    fn applyMigration6(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs(
            \\create virtual table if not exists search_entries using fts5(
            \\  entry_kind unindexed,
            \\  origin unindexed,
            \\  session_id unindexed,
            \\  turn_id unindexed,
            \\  step_hash unindexed,
            \\  timestamp unindexed,
            \\  seq unindexed,
            \\  label unindexed,
            \\  content,
            \\  tokenize='unicode61'
            \\)
        );

        try self.db.execNoArgs(
            \\insert into search_entries (entry_kind, origin, session_id, turn_id, step_hash, timestamp, seq, label, content)
            \\select 'message', s.session_origin, s.session_id, s.turn_id, m.step_hash,
            \\       cast(s.timestamp as text), cast(m.seq as text), m.role, m.content
            \\from messages m
            \\join steps s on s.hash = m.step_hash
        );
        try self.db.execNoArgs(
            \\insert into search_entries (entry_kind, origin, session_id, turn_id, step_hash, timestamp, seq, label, content)
            \\select 'tool_args', s.session_origin, s.session_id, s.turn_id, t.step_hash,
            \\       cast(s.timestamp as text), cast(t.seq as text), t.tool_name, t.args
            \\from tool_calls t
            \\join steps s on s.hash = t.step_hash
        );
        try self.db.execNoArgs(
            \\insert into search_entries (entry_kind, origin, session_id, turn_id, step_hash, timestamp, seq, label, content)
            \\select 'tool_result', s.session_origin, s.session_id, s.turn_id, t.step_hash,
            \\       cast(s.timestamp as text), cast(t.seq as text), t.tool_name, t.result
            \\from tool_calls t
            \\join steps s on s.hash = t.step_hash
            \\where t.result is not null
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 6)},
        );

        try self.db.execNoArgs("pragma user_version = 6");
        try self.db.commit();
    }

    fn applyMigration7(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs(
            \\create table if not exists packed_objects (
            \\  hash         text primary key references objects(hash) on delete cascade,
            \\  pack_name    text not null,
            \\  offset       integer not null,
            \\  packed_len   integer not null,
            \\  unpacked_len integer not null,
            \\  kind         text not null,
            \\  encoding     text not null,
            \\  base_hash    text,
            \\  depth        integer not null,
            \\  crc32        integer not null
            \\)
        );
        try self.db.execNoArgs(
            "create index if not exists packed_objects_pack_name_offset on packed_objects(pack_name, offset)",
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 7)},
        );

        try self.db.execNoArgs("pragma user_version = 7");
        try self.db.commit();
    }

    fn applyMigration8(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs("alter table steps add column git_commit text");
        try self.db.execNoArgs("alter table steps add column git_branch text");
        try self.db.execNoArgs("alter table steps add column git_dirty integer");
        try self.db.execNoArgs(
            "create index if not exists steps_git_commit on steps(git_commit) where git_commit is not null",
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 8)},
        );

        try self.db.execNoArgs("pragma user_version = 8");
        try self.db.commit();
    }

    /// Insert or update a session's HEAD pointer.
    pub fn upsertSession(
        self: Index,
        origin: []const u8,
        session_id: []const u8,
        head_hash: ?[]const u8,
    ) !void {
        try self.db.exec(
            \\insert into sessions (origin, session_id, head_hash, updated_at)
            \\values (?, ?, ?, unixepoch())
            \\on conflict (origin, session_id) do update set
            \\  head_hash  = excluded.head_hash,
            \\  updated_at = excluded.updated_at
        , .{ origin, session_id, head_hash });
    }

    /// Insert a step record, ignoring duplicates.
    pub fn insertStep(
        self: Index,
        hash: []const u8,
        session_origin: []const u8,
        session_id: []const u8,
        turn_id: []const u8,
        parent_hash: ?[]const u8,
        tree_hash: []const u8,
        timestamp: i64,
        model: ?[]const u8,
        outcome: ?[]const u8,
        git_commit: ?[]const u8,
        git_branch: ?[]const u8,
        git_dirty: ?bool,
        preview: ?[]const u8,
    ) !void {
        const git_dirty_int: ?i64 = if (git_dirty) |dirty| if (dirty) 1 else 0 else null;
        try self.db.exec(
            \\insert or ignore into steps
            \\  (hash, session_origin, session_id, turn_id, parent_hash, tree_hash, timestamp, model, outcome, git_commit, git_branch, git_dirty, preview)
            \\values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        , .{ hash, session_origin, session_id, turn_id, parent_hash, tree_hash, timestamp, model, outcome, git_commit, git_branch, git_dirty_int, preview });
    }

    /// Remove all step and session rows (used by reindex).
    pub fn truncate(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();
        try self.db.execNoArgs("delete from search_entries");
        try self.db.execNoArgs("delete from tool_calls");
        try self.db.execNoArgs("delete from messages");
        try self.db.execNoArgs("delete from steps");
        try self.db.execNoArgs("delete from sessions");
        try self.db.execNoArgs("delete from blame_maps");
        try self.db.execNoArgs("delete from packed_objects");
        try self.db.execNoArgs("delete from objects");
        try self.db.execNoArgs("delete from meta");
        try self.db.commit();
    }

    pub fn insertObject(self: Index, hash: []const u8, kind: []const u8, size: usize) !void {
        try self.db.exec(
            "insert or ignore into objects (hash, kind, size) values (?, ?, ?)",
            .{ hash, kind, @as(i64, @intCast(size)) },
        );
    }

    pub fn hasObject(self: Index, hash: []const u8) !bool {
        const row = try self.db.row(
            "select 1 from objects where hash=? limit 1",
            .{hash},
        );
        if (row) |r| {
            defer r.deinit();
            return true;
        }
        return false;
    }

    pub const PackedObjectRow = struct {
        pack_name: []u8,
        offset: u64,
        packed_len: u64,
        unpacked_len: u64,
        kind: []u8,
        encoding: []u8,
        base_hash: ?[]u8,
        depth: u16,
        crc32: u32,

        pub fn deinit(self: *PackedObjectRow, gpa: std.mem.Allocator) void {
            gpa.free(self.pack_name);
            gpa.free(self.kind);
            gpa.free(self.encoding);
            if (self.base_hash) |base_hash| gpa.free(base_hash);
            self.* = undefined;
        }
    };

    pub fn insertPackedObject(
        self: Index,
        hash: []const u8,
        pack_name: []const u8,
        offset: u64,
        packed_len: u64,
        unpacked_len: u64,
        kind: []const u8,
        encoding: []const u8,
        base_hash: ?[]const u8,
        depth: u16,
        crc32: u32,
    ) !void {
        try self.db.exec(
            \\insert into packed_objects (hash, pack_name, offset, packed_len, unpacked_len, kind, encoding, base_hash, depth, crc32)
            \\values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \\on conflict(hash) do update set
            \\  pack_name = excluded.pack_name,
            \\  offset = excluded.offset,
            \\  packed_len = excluded.packed_len,
            \\  unpacked_len = excluded.unpacked_len,
            \\  kind = excluded.kind,
            \\  encoding = excluded.encoding,
            \\  base_hash = excluded.base_hash,
            \\  depth = excluded.depth,
            \\  crc32 = excluded.crc32
        , .{
            hash,
            pack_name,
            @as(i64, @intCast(offset)),
            @as(i64, @intCast(packed_len)),
            @as(i64, @intCast(unpacked_len)),
            kind,
            encoding,
            base_hash,
            @as(i64, depth),
            @as(i64, crc32),
        });
    }

    pub fn lookupPackedObject(self: Index, gpa: std.mem.Allocator, hash: []const u8) !?PackedObjectRow {
        const row = try self.db.row(
            \\select pack_name, offset, packed_len, unpacked_len, kind, encoding, base_hash, depth, crc32
            \\from packed_objects where hash=? limit 1
        , .{hash}) orelse return null;
        defer row.deinit();

        return .{
            .pack_name = try gpa.dupe(u8, row.get([]const u8, 0)),
            .offset = @intCast(row.get(i64, 1)),
            .packed_len = @intCast(row.get(i64, 2)),
            .unpacked_len = @intCast(row.get(i64, 3)),
            .kind = try gpa.dupe(u8, row.get([]const u8, 4)),
            .encoding = try gpa.dupe(u8, row.get([]const u8, 5)),
            .base_hash = if (row.get(?[]const u8, 6)) |base_hash| try gpa.dupe(u8, base_hash) else null,
            .depth = @intCast(row.get(i64, 7)),
            .crc32 = @intCast(row.get(i64, 8)),
        };
    }

    pub fn countObjects(self: Index) !i64 {
        const row = try self.db.row("select count(*) from objects", .{}) orelse return 0;
        defer row.deinit();
        return row.get(i64, 0);
    }

    pub fn lookupObjectPrefix(self: Index, prefix: []const u8) !ObjectPrefixMatches {
        var pattern_buf: [65]u8 = undefined;
        if (prefix.len > 64) return error.InvalidHash;
        @memcpy(pattern_buf[0..prefix.len], prefix);
        pattern_buf[prefix.len] = '%';
        const pattern = pattern_buf[0 .. prefix.len + 1];

        var rows = try self.db.rows(
            "select hash from objects where hash like ? order by hash asc limit 3",
            .{pattern},
        );
        defer rows.deinit();

        var matches: ObjectPrefixMatches = .{};
        while (rows.next()) |row| {
            const hash = row.get([]const u8, 0);
            if (hash.len != 64) continue;
            if (matches.count < matches.hashes.len) {
                @memcpy(matches.hashes[matches.count][0..], hash);
            }
            matches.count += 1;
        }
        if (rows.err) |err| return err;
        return matches;
    }

    pub fn setObjectsComplete(self: Index, complete: bool) !void {
        try self.metaSet(objects_complete_meta_key, if (complete) "1" else "0");
    }

    pub fn getObjectsComplete(self: Index) !?bool {
        const row = try self.db.row(
            "select value from meta where key=?",
            .{objects_complete_meta_key},
        ) orelse return null;
        defer row.deinit();
        return std.mem.eql(u8, row.get([]const u8, 0), "1");
    }

    fn applyMigration9(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs(
            \\create table if not exists blame_maps (
            \\  path           text not null,
            \\  step_hash      text not null,
            \\  blame_hash     text not null,
            \\  blob_hash      text not null,
            \\  session_origin text not null,
            \\  session_id     text not null,
            \\  timestamp      integer not null,
            \\  primary key (path, step_hash)
            \\)
        );
        try self.db.execNoArgs(
            "create index if not exists blame_maps_path_order on blame_maps(path, timestamp desc, step_hash desc)",
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 9)},
        );

        try self.db.execNoArgs("pragma user_version = 9");
        try self.db.commit();
    }

    fn applyMigration10(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs("alter table steps add column outcome text");
        try self.db.execNoArgs(
            "create index if not exists steps_outcome_timestamp on steps(outcome, timestamp desc) where outcome is not null",
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 10)},
        );

        try self.db.execNoArgs("pragma user_version = 10");
        try self.db.commit();
    }

    fn applyMigration11(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs("alter table steps add column model text");
        try self.db.execNoArgs(
            "create index if not exists steps_model_timestamp on steps(model, timestamp desc) where model is not null",
        );

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 11)},
        );

        try self.db.execNoArgs("pragma user_version = 11");
        try self.db.commit();
    }

    fn applyMigration12(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();

        try self.db.execNoArgs("alter table steps add column preview text");

        try self.db.exec(
            "insert into schema_migrations (version) values (?)",
            .{@as(i64, 12)},
        );

        try self.db.execNoArgs("pragma user_version = 12");
        try self.db.commit();
    }

    /// Insert or update the blame_maps row for (path, step_hash).
    pub fn insertBlameMap(
        self: Index,
        path: []const u8,
        step_hash: []const u8,
        blame_hash: []const u8,
        blob_hash: []const u8,
        session_origin: []const u8,
        session_id: []const u8,
        timestamp: i64,
    ) !void {
        try self.db.exec(
            \\insert into blame_maps
            \\  (path, step_hash, blame_hash, blob_hash, session_origin, session_id, timestamp)
            \\values (?, ?, ?, ?, ?, ?, ?)
            \\on conflict(path, step_hash) do update set
            \\  blame_hash = excluded.blame_hash,
            \\  blob_hash  = excluded.blob_hash,
            \\  timestamp  = excluded.timestamp
        , .{ path, step_hash, blame_hash, blob_hash, session_origin, session_id, timestamp });
    }

    pub const BlameRow = struct {
        step_hash: [64]u8,
        blame_hash: [64]u8,
        blob_hash: [64]u8,
        timestamp: i64,
    };

    fn rowToBlame(row: anytype) ?BlameRow {
        const step_hex = row.get([]const u8, 0);
        const blame_hex = row.get([]const u8, 1);
        const blob_hex = row.get([]const u8, 2);
        if (step_hex.len != 64 or blame_hex.len != 64 or blob_hex.len != 64) return null;
        var out: BlameRow = .{ .step_hash = undefined, .blame_hash = undefined, .blob_hash = undefined, .timestamp = row.get(i64, 3) };
        @memcpy(out.step_hash[0..], step_hex);
        @memcpy(out.blame_hash[0..], blame_hex);
        @memcpy(out.blob_hash[0..], blob_hex);
        return out;
    }

    /// Latest blame row for a path, by (timestamp, step_hash) descending.
    pub fn queryLatestBlame(self: Index, path: []const u8) !?BlameRow {
        const row = try self.db.row(
            \\select step_hash, blame_hash, blob_hash, timestamp from blame_maps
            \\where path=? order by timestamp desc, step_hash desc limit 1
        , .{path}) orelse return null;
        defer row.deinit();
        return rowToBlame(row);
    }

    /// Latest blame row for a path at or before the given (timestamp, step_hash).
    pub fn queryBlameAtStep(self: Index, path: []const u8, timestamp: i64, step_hash: []const u8) !?BlameRow {
        const row = try self.db.row(
            \\select step_hash, blame_hash, blob_hash, timestamp from blame_maps
            \\where path=? and (timestamp < ? or (timestamp = ? and step_hash <= ?))
            \\order by timestamp desc, step_hash desc limit 1
        , .{ path, timestamp, timestamp, step_hash }) orelse return null;
        defer row.deinit();
        return rowToBlame(row);
    }

    pub fn clearBlameMaps(self: Index) !void {
        try self.db.execNoArgs("delete from blame_maps");
    }

    pub const StepMeta = struct {
        origin: []const u8,
        model: ?[]const u8 = null,
        timestamp: i64,

        pub fn deinit(self: *StepMeta, gpa: std.mem.Allocator) void {
            gpa.free(self.origin);
            if (self.model) |value| gpa.free(value);
            self.* = undefined;
        }
    };

    /// Origin, model, and timestamp for an attributing step.
    pub fn queryStepMeta(self: Index, gpa: std.mem.Allocator, step_hash: []const u8) !?StepMeta {
        if (try self.db.row(
            "select session_origin, model, timestamp from steps where hash=? limit 1",
            .{step_hash},
        )) |row| {
            defer row.deinit();
            return StepMeta{
                .origin = try gpa.dupe(u8, row.get([]const u8, 0)),
                .model = if (row.get(?[]const u8, 1)) |value| try gpa.dupe(u8, value) else null,
                .timestamp = row.get(i64, 2),
            };
        }

        const row = try self.db.row(
            "select session_origin, timestamp from blame_maps where step_hash=? limit 1",
            .{step_hash},
        ) orelse return null;
        defer row.deinit();
        return StepMeta{
            .origin = try gpa.dupe(u8, row.get([]const u8, 0)),
            .timestamp = row.get(i64, 1),
        };
    }

    /// Look up step meta for a set of distinct step hashes in one query.
    /// Returns a map keyed by the 64-char lowercase hex step hash, mirroring
    /// queryStepMeta exactly (including the blame_maps fallback) just batched
    /// into one round trip per chunk instead of one per hash.
    // Note: chunked into 500 placeholders so we stay far under
    // SQLITE_MAX_VARIABLE_NUMBER (32766); raise chunk size if profiling shows it.
    pub fn queryStepMetaBatch(
        self: Index,
        arena: std.mem.Allocator,
        step_hashes: []const []const u8,
    ) !std.StringHashMap(StepMeta) {
        var map = std.StringHashMap(StepMeta).init(arena);
        errdefer map.deinit();
        if (step_hashes.len == 0) return map;

        const chunk_size: usize = 500;

        // First pass: steps table.
        var i: usize = 0;
        while (i < step_hashes.len) : (i += chunk_size) {
            const end = @min(i + chunk_size, step_hashes.len);
            const chunk = step_hashes[i..end];

            var placeholders: std.ArrayList(u8) = .empty;
            try placeholders.appendSlice(arena, "?");
            for (chunk[1..]) |_| try placeholders.appendSlice(arena, ", ?");

            const sql = try std.fmt.allocPrint(
                arena,
                "select hash, session_origin, model, timestamp from steps where hash in ({s})",
                .{placeholders.items},
            );

            const stmt = try self.db.prepare(sql);
            defer stmt.deinit();
            for (chunk, 0..) |h, idx| try stmt.bindValue(h, idx);
            while (try stmt.step()) {
                const step_hex = try arena.dupe(u8, stmt.text(0));
                const meta = StepMeta{
                    .origin = try arena.dupe(u8, stmt.text(1)),
                    .model = blk: {
                        if (stmt.nullableText(2)) |value| break :blk try arena.dupe(u8, value);
                        break :blk null;
                    },
                    .timestamp = stmt.int(3),
                };
                try map.put(step_hex, meta);
            }
        }

        // Fallback pass: any hashes absent from steps come from blame_maps.
        // Note: each step's blame_maps rows share origin/timestamp (one
        // recording produces them), so first-seen-per-hash matches queryStepMeta's
        // `limit 1` arbitrary pick; keep that with the contains() guard.
        var missing: std.ArrayList([]const u8) = .empty;
        for (step_hashes) |h| {
            if (!map.contains(h)) try missing.append(arena, h);
        }
        if (missing.items.len == 0) return map;

        var j: usize = 0;
        while (j < missing.items.len) : (j += chunk_size) {
            const end = @min(j + chunk_size, missing.items.len);
            const chunk = missing.items[j..end];

            var placeholders: std.ArrayList(u8) = .empty;
            try placeholders.appendSlice(arena, "?");
            for (chunk[1..]) |_| try placeholders.appendSlice(arena, ", ?");

            const sql = try std.fmt.allocPrint(
                arena,
                "select step_hash, session_origin, timestamp from blame_maps where step_hash in ({s})",
                .{placeholders.items},
            );

            const stmt = try self.db.prepare(sql);
            defer stmt.deinit();
            for (chunk, 0..) |h, idx| try stmt.bindValue(h, idx);
            while (try stmt.step()) {
                const step_hex = try arena.dupe(u8, stmt.text(0));
                if (map.contains(step_hex)) continue;
                const meta = StepMeta{
                    .origin = try arena.dupe(u8, stmt.text(1)),
                    .model = null,
                    .timestamp = stmt.int(2),
                };
                try map.put(step_hex, meta);
            }
        }

        return map;
    }

    /// Append the distinct blame object hashes referenced by blame_maps to `out`.
    pub fn collectBlameHashes(self: Index, gpa: std.mem.Allocator, out: *std.ArrayList([64]u8)) !void {
        var rs = try self.db.rows("select distinct blame_hash from blame_maps", .{});
        defer rs.deinit();
        while (rs.next()) |row| {
            const hex = row.get([]const u8, 0);
            if (hex.len != 64) continue;
            var buf: [64]u8 = undefined;
            @memcpy(buf[0..], hex);
            try out.append(gpa, buf);
        }
        if (rs.err) |err| return err;
    }

    /// Insert a message row for a step. Idempotent via (step_hash, seq) uniqueness.
    pub fn insertMessage(
        self: Index,
        step_hash: []const u8,
        seq: i64,
        role: []const u8,
        content: []const u8,
    ) !void {
        try self.db.exec(
            "insert or ignore into messages (step_hash, seq, role, content) values (?, ?, ?, ?)",
            .{ step_hash, seq, role, content },
        );
        if (self.db.changes() == 0) return;
        try self.insertSearchEntry("message", step_hash, seq, role, content);
    }

    /// Insert a tool_call row for a step. Idempotent via (step_hash, seq) uniqueness.
    pub fn insertToolCall(
        self: Index,
        step_hash: []const u8,
        seq: i64,
        tool_name: []const u8,
        args: []const u8,
        result: ?[]const u8,
    ) !void {
        try self.db.exec(
            "insert or ignore into tool_calls (step_hash, seq, tool_name, args, result) values (?, ?, ?, ?, ?)",
            .{ step_hash, seq, tool_name, args, result },
        );
        if (self.db.changes() == 0) return;
        try self.insertSearchEntry("tool_args", step_hash, seq, tool_name, args);
        if (result) |result_text| {
            try self.insertSearchEntry("tool_result", step_hash, seq, tool_name, result_text);
        }
    }

    fn insertSearchEntry(
        self: Index,
        entry_kind: []const u8,
        step_hash: []const u8,
        seq: i64,
        label: []const u8,
        content: []const u8,
    ) !void {
        try self.db.exec(
            \\insert into search_entries (entry_kind, origin, session_id, turn_id, step_hash, timestamp, seq, label, content)
            \\select ?, session_origin, session_id, turn_id, hash, cast(timestamp as text), cast(? as text), ?, ?
            \\from steps where hash=?
        , .{ entry_kind, seq, label, content, step_hash });
    }

    pub fn hasStep(self: Index, hash: []const u8) !bool {
        const row = try self.db.row(
            "select 1 from steps where hash=? limit 1",
            .{hash},
        );
        if (row) |r| {
            defer r.deinit();
            return true;
        }
        return false;
    }

    pub fn countSessionSteps(self: Index, origin: []const u8, session_id: []const u8) !i64 {
        const row = try self.db.row(
            "select count(*) from steps where session_origin=? and session_id=?",
            .{ origin, session_id },
        ) orelse return 0;
        defer row.deinit();
        return row.get(i64, 0);
    }

    pub fn maxStepTimestamp(self: Index) !?i64 {
        const row = try self.db.row("select max(timestamp) from steps", .{}) orelse return null;
        defer row.deinit();
        return row.get(?i64, 0);
    }

    pub fn metaSet(self: Index, key: []const u8, value: []const u8) !void {
        try self.db.exec(
            \\insert into meta (key, value) values (?, ?)
            \\on conflict(key) do update set value=excluded.value
        , .{ key, value });
    }

    pub fn metaGet(self: Index, gpa: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const row = try self.db.row(
            "select value from meta where key=?",
            .{key},
        ) orelse return null;
        defer row.deinit();
        return try gpa.dupe(u8, row.get([]const u8, 0));
    }

    pub fn metaDelete(self: Index, key: []const u8) !void {
        try self.db.exec(
            "delete from meta where key=?",
            .{key},
        );
    }

    pub fn addMetaCounter(self: Index, key: []const u8, delta: i64) !void {
        try self.db.exec(
            \\insert into meta (key, value) values (?, ?)
            \\on conflict(key) do update set
            \\  value = cast(coalesce(meta.value, '0') as integer) + cast(excluded.value as integer)
        , .{ key, delta });
    }

    pub fn readMetaCounter(self: Index, key: []const u8) !i64 {
        const row = try self.db.row(
            "select cast(value as integer) from meta where key=?",
            .{key},
        ) orelse return 0;
        defer row.deinit();
        return row.get(i64, 0);
    }

    /// Return the 64-char hex hash of the step committed for this turn, or null.
    pub fn queryStepHash(
        self: Index,
        origin: []const u8,
        session_id: []const u8,
        turn_id: []const u8,
    ) !?[64]u8 {
        const row = try self.db.row(
            "select hash from steps where session_origin=? and session_id=? and turn_id=?",
            .{ origin, session_id, turn_id },
        ) orelse return null;
        defer row.deinit();
        const hash_str = row.get([]const u8, 0);
        if (hash_str.len != 64) return null;
        var buf: [64]u8 = undefined;
        @memcpy(&buf, hash_str);
        return buf;
    }

    /// Count the number of sessions in the index.
    pub fn countSessions(self: Index) !i64 {
        const row = try self.db.row("select count(*) from sessions", .{}) orelse return 0;
        defer row.deinit();
        return row.get(i64, 0);
    }

    /// Count the total number of steps in the index.
    pub fn countSteps(self: Index) !i64 {
        const row = try self.db.row("select count(*) from steps", .{}) orelse return 0;
        defer row.deinit();
        return row.get(i64, 0);
    }

    pub fn statsSummary(self: Index, options: StatsOptions) !StatsSummaryRow {
        const row = try self.db.row(
            \\select
            \\  (select count(*) from sessions
            \\   where (? is null or origin = ?)
            \\     and (? is null or session_id = ?)),
            \\  (select count(*) from steps
            \\   where (? is null or session_origin = ?)
            \\     and (? is null or session_id = ?)),
            \\  (select count(distinct session_origin || char(0) || session_id || char(0) || turn_id) from steps
            \\   where (? is null or session_origin = ?)
            \\     and (? is null or session_id = ?)),
            \\  (select min(timestamp) from steps
            \\   where (? is null or session_origin = ?)
            \\     and (? is null or session_id = ?)),
            \\  (select max(timestamp) from steps
            \\   where (? is null or session_origin = ?)
            \\     and (? is null or session_id = ?))
        , .{
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
        }) orelse return .{};
        defer row.deinit();
        return .{
            .session_count = row.get(i64, 0),
            .step_count = row.get(i64, 1),
            .turn_count = row.get(i64, 2),
            .first_timestamp = row.get(?i64, 3),
            .last_timestamp = row.get(?i64, 4),
        };
    }

    pub fn listSessionStats(self: Index, gpa: std.mem.Allocator, options: StatsOptions) ![]const SessionStatsRow {
        var list: std.ArrayList(SessionStatsRow) = .empty;
        errdefer {
            for (list.items) |row| freeSessionStatsRow(gpa, row);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select s.origin, s.session_id, count(st.hash), count(distinct st.turn_id), min(st.timestamp), max(st.timestamp)
            \\from sessions s
            \\left join steps st on st.session_origin = s.origin and st.session_id = s.session_id
            \\where (? is null or s.origin = ?)
            \\  and (? is null or s.session_id = ?)
            \\group by s.origin, s.session_id
            \\order by max(st.timestamp) desc, s.updated_at desc, s.origin asc, s.session_id asc
        , .{
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
        });
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, .{
                .origin = try gpa.dupe(u8, row.get([]const u8, 0)),
                .session_id = try gpa.dupe(u8, row.get([]const u8, 1)),
                .step_count = row.get(i64, 2),
                .turn_count = row.get(i64, 3),
                .first_timestamp = row.get(?i64, 4),
                .last_timestamp = row.get(?i64, 5),
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn listToolCounts(self: Index, gpa: std.mem.Allocator, options: StatsOptions, limit: usize) ![]const ToolCountRow {
        var list: std.ArrayList(ToolCountRow) = .empty;
        errdefer {
            for (list.items) |row| freeToolCountRow(gpa, row);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select case when trim(t.tool_name) = '' then '(unknown)' else t.tool_name end as tool_name,
            \\       count(*) as call_count
            \\from tool_calls t
            \\join steps s on s.hash = t.step_hash
            \\where (? is null or s.session_origin = ?)
            \\  and (? is null or s.session_id = ?)
            \\group by tool_name
            \\order by call_count desc, tool_name asc
            \\limit ?
        , .{
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            @as(i64, @intCast(limit)),
        });
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, .{
                .tool_name = try gpa.dupe(u8, row.get([]const u8, 0)),
                .count = row.get(i64, 1),
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn listStatsSteps(self: Index, gpa: std.mem.Allocator, options: StatsOptions, limit: usize) ![]const StepRow {
        var list: std.ArrayList(StepRow) = .empty;
        errdefer {
            for (list.items) |r| freeStepRow(gpa, r);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select hash, turn_id, parent_hash, tree_hash, timestamp, model, git_commit, git_branch, coalesce(git_dirty, -1)
            \\from steps
            \\where (? is null or session_origin = ?)
            \\  and (? is null or session_id = ?)
            \\order by timestamp asc, hash asc
            \\limit ?
        , .{
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            @as(i64, @intCast(limit)),
        });
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, StepRow{
                .hash = try gpa.dupe(u8, row.get([]const u8, 0)),
                .turn_id = try gpa.dupe(u8, row.get([]const u8, 1)),
                .parent_hash = if (row.get(?[]const u8, 2)) |p| try gpa.dupe(u8, p) else null,
                .tree_hash = try gpa.dupe(u8, row.get([]const u8, 3)),
                .timestamp = row.get(i64, 4),
                .model = if (row.get(?[]const u8, 5)) |model| try gpa.dupe(u8, model) else null,
                .git_commit = if (row.get(?[]const u8, 6)) |commit| try gpa.dupe(u8, commit) else null,
                .git_branch = if (row.get(?[]const u8, 7)) |branch| try gpa.dupe(u8, branch) else null,
                .git_dirty = dirtyFromInt(row.get(i64, 8)),
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    /// List all sessions ordered by most recently updated first.
    /// Caller must call `freeSessionRows(gpa, result)` when done.
    pub fn listSessions(self: Index, gpa: std.mem.Allocator) ![]const SessionRow {
        var list: std.ArrayList(SessionRow) = .empty;
        errdefer {
            for (list.items) |r| freeSessionRow(gpa, r);
            list.deinit(gpa);
        }
        var rs = try self.db.rows(
            "select origin, session_id, head_hash, updated_at from sessions order by updated_at desc",
            .{},
        );
        defer rs.deinit();
        while (rs.next()) |row| {
            try list.append(gpa, SessionRow{
                .origin = try gpa.dupe(u8, row.get([]const u8, 0)),
                .session_id = try gpa.dupe(u8, row.get([]const u8, 1)),
                .head_hash = if (row.get(?[]const u8, 2)) |h| try gpa.dupe(u8, h) else null,
                .updated_at = row.get(i64, 3),
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    /// List all steps for a session ordered by timestamp ascending.
    /// Caller must call `freeStepRows(gpa, result)` when done.
    pub fn listSteps(
        self: Index,
        gpa: std.mem.Allocator,
        origin: []const u8,
        session_id: []const u8,
    ) ![]const StepRow {
        var list: std.ArrayList(StepRow) = .empty;
        errdefer {
            for (list.items) |r| freeStepRow(gpa, r);
            list.deinit(gpa);
        }
        var rs = try self.db.rows(
            \\select hash, turn_id, parent_hash, tree_hash, timestamp, model, git_commit, git_branch, coalesce(git_dirty, -1)
            \\from steps where session_origin=? and session_id=?
            \\order by timestamp asc
        , .{ origin, session_id });
        defer rs.deinit();
        while (rs.next()) |row| {
            try list.append(gpa, StepRow{
                .hash = try gpa.dupe(u8, row.get([]const u8, 0)),
                .turn_id = try gpa.dupe(u8, row.get([]const u8, 1)),
                .parent_hash = if (row.get(?[]const u8, 2)) |p| try gpa.dupe(u8, p) else null,
                .tree_hash = try gpa.dupe(u8, row.get([]const u8, 3)),
                .timestamp = row.get(i64, 4),
                .model = if (row.get(?[]const u8, 5)) |model| try gpa.dupe(u8, model) else null,
                .git_commit = if (row.get(?[]const u8, 6)) |commit| try gpa.dupe(u8, commit) else null,
                .git_branch = if (row.get(?[]const u8, 7)) |branch| try gpa.dupe(u8, branch) else null,
                .git_dirty = dirtyFromInt(row.get(i64, 8)),
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn listRecentSteps(
        self: Index,
        gpa: std.mem.Allocator,
        options: TimelineOptions,
    ) ![]const TimelineRow {
        var list: std.ArrayList(TimelineRow) = .empty;
        errdefer {
            for (list.items) |row| freeTimelineRow(gpa, row);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select hash, session_origin, session_id, turn_id, timestamp, model, git_commit, git_branch, coalesce(git_dirty, -1), preview
            \\from steps
            \\where (? is null or session_origin = ?)
            \\  and (? is null or session_id = ?)
            \\  and (? is null or timestamp >= ?)
            \\  and (? is null or timestamp < ?)
            \\order by timestamp desc, hash desc
            \\limit ?
        , .{
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.since_ms,
            options.since_ms,
            options.until_ms_exclusive,
            options.until_ms_exclusive,
            @as(i64, @intCast(options.limit)),
        });
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, .{
                .hash = try gpa.dupe(u8, row.get([]const u8, 0)),
                .origin = try gpa.dupe(u8, row.get([]const u8, 1)),
                .session_id = try gpa.dupe(u8, row.get([]const u8, 2)),
                .turn_id = try gpa.dupe(u8, row.get([]const u8, 3)),
                .timestamp = row.get(i64, 4),
                .model = if (row.get(?[]const u8, 5)) |model| try gpa.dupe(u8, model) else null,
                .git_commit = if (row.get(?[]const u8, 6)) |commit| try gpa.dupe(u8, commit) else null,
                .git_branch = if (row.get(?[]const u8, 7)) |branch| try gpa.dupe(u8, branch) else null,
                .git_dirty = dirtyFromInt(row.get(i64, 8)),
                .preview = if (row.get(?[]const u8, 9)) |preview| try gpa.dupe(u8, preview) else null,
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn latestWatchRowid(self: Index, options: WatchOptions) !?i64 {
        const row = try self.db.row(
            \\select rowid
            \\from steps
            \\where (? is null or session_origin = ?)
            \\  and (? is null or session_id = ?)
            \\order by rowid desc
            \\limit 1
        , .{
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
        }) orelse return null;
        defer row.deinit();
        return row.get(i64, 0);
    }

    pub fn listStepsAfterCursor(
        self: Index,
        gpa: std.mem.Allocator,
        options: WatchOptions,
    ) ![]const TimelineRow {
        var list: std.ArrayList(TimelineRow) = .empty;
        errdefer {
            for (list.items) |row| freeTimelineRow(gpa, row);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select rowid, hash, session_origin, session_id, turn_id, timestamp, model, git_commit, git_branch, coalesce(git_dirty, -1), preview
            \\from steps
            \\where rowid > ?
            \\  and (? is null or session_origin = ?)
            \\  and (? is null or session_id = ?)
            \\  and (? is null or timestamp >= ?)
            \\order by rowid asc
            \\limit ?
        , .{
            options.after_rowid,
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.since_ms,
            options.since_ms,
            @as(i64, @intCast(options.limit)),
        });
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, .{
                .rowid = row.get(i64, 0),
                .hash = try gpa.dupe(u8, row.get([]const u8, 1)),
                .origin = try gpa.dupe(u8, row.get([]const u8, 2)),
                .session_id = try gpa.dupe(u8, row.get([]const u8, 3)),
                .turn_id = try gpa.dupe(u8, row.get([]const u8, 4)),
                .timestamp = row.get(i64, 5),
                .model = if (row.get(?[]const u8, 6)) |model| try gpa.dupe(u8, model) else null,
                .git_commit = if (row.get(?[]const u8, 7)) |commit| try gpa.dupe(u8, commit) else null,
                .git_branch = if (row.get(?[]const u8, 8)) |branch| try gpa.dupe(u8, branch) else null,
                .git_dirty = dirtyFromInt(row.get(i64, 9)),
                .preview = if (row.get(?[]const u8, 10)) |preview| try gpa.dupe(u8, preview) else null,
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn searchEntries(
        self: Index,
        gpa: std.mem.Allocator,
        options: SearchOptions,
    ) ![]const SearchRow {
        var list: std.ArrayList(SearchRow) = .empty;
        errdefer {
            for (list.items) |row| freeSearchRow(gpa, row);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select entry_kind, origin, session_id, turn_id, step_hash, cast(timestamp as integer), label,
            \\       snippet(search_entries, 8, '[', ']', '…', ?)
            \\from search_entries
            \\where search_entries match ?
            \\  and (? is null or origin = ?)
            \\  and (? is null or session_id = ?)
            \\  and (? is null or cast(timestamp as integer) >= ?)
            \\  and (? is null or cast(timestamp as integer) < ?)
            \\order by cast(timestamp as integer) desc, step_hash desc, cast(seq as integer) asc, entry_kind asc
            \\limit ?
        , .{
            @as(i64, @intCast(options.context_tokens)),
            options.match_query,
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.since_ms,
            options.since_ms,
            options.until_ms_exclusive,
            options.until_ms_exclusive,
            @as(i64, @intCast(options.limit)),
        });
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, .{
                .entry_kind = try gpa.dupe(u8, row.get([]const u8, 0)),
                .origin = try gpa.dupe(u8, row.get([]const u8, 1)),
                .session_id = try gpa.dupe(u8, row.get([]const u8, 2)),
                .turn_id = try gpa.dupe(u8, row.get([]const u8, 3)),
                .step_hash = try gpa.dupe(u8, row.get([]const u8, 4)),
                .timestamp = row.get(i64, 5),
                .label = try gpa.dupe(u8, row.get([]const u8, 6)),
                .snippet = try gpa.dupe(u8, row.get([]const u8, 7)),
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn listRecallStepsForPath(
        self: Index,
        gpa: std.mem.Allocator,
        options: RecallPathOptions,
    ) ![]const RecallRow {
        var list: std.ArrayList(RecallRow) = .empty;
        errdefer {
            for (list.items) |row| freeRecallRow(gpa, row);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select s.hash, s.session_origin, s.session_id, s.turn_id, s.timestamp, s.model, s.outcome,
            \\       s.git_commit, s.git_branch, coalesce(s.git_dirty, -1), s.preview
            \\from blame_maps b
            \\join steps s on s.hash = b.step_hash
            \\where b.path = ?
            \\  and (? is null or s.session_origin = ?)
            \\  and (? is null or s.session_id = ?)
            \\  and (? is null or s.outcome = ?)
            \\order by s.timestamp desc, s.hash desc
            \\limit ?
        , .{
            options.path,
            options.origin,
            options.origin,
            options.session_id,
            options.session_id,
            options.outcome,
            options.outcome,
            @as(i64, @intCast(options.limit)),
        });
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, .{
                .hash = try gpa.dupe(u8, row.get([]const u8, 0)),
                .origin = try gpa.dupe(u8, row.get([]const u8, 1)),
                .session_id = try gpa.dupe(u8, row.get([]const u8, 2)),
                .turn_id = try gpa.dupe(u8, row.get([]const u8, 3)),
                .timestamp = row.get(i64, 4),
                .model = if (row.get(?[]const u8, 5)) |value| try gpa.dupe(u8, value) else null,
                .outcome = if (row.get(?[]const u8, 6)) |value| try gpa.dupe(u8, value) else null,
                .git_commit = if (row.get(?[]const u8, 7)) |value| try gpa.dupe(u8, value) else null,
                .git_branch = if (row.get(?[]const u8, 8)) |value| try gpa.dupe(u8, value) else null,
                .git_dirty = dirtyFromInt(row.get(i64, 9)),
                .preview = if (row.get(?[]const u8, 10)) |value| try gpa.dupe(u8, value) else null,
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn getRecallStepByHash(self: Index, gpa: std.mem.Allocator, hash: []const u8) !?RecallRow {
        const row = try self.db.row(
            \\select hash, session_origin, session_id, turn_id, timestamp, model, outcome,
            \\       git_commit, git_branch, coalesce(git_dirty, -1), preview
            \\from steps
            \\where hash = ?
            \\limit 1
        , .{hash}) orelse return null;
        defer row.deinit();

        return .{
            .hash = try gpa.dupe(u8, row.get([]const u8, 0)),
            .origin = try gpa.dupe(u8, row.get([]const u8, 1)),
            .session_id = try gpa.dupe(u8, row.get([]const u8, 2)),
            .turn_id = try gpa.dupe(u8, row.get([]const u8, 3)),
            .timestamp = row.get(i64, 4),
            .model = if (row.get(?[]const u8, 5)) |value| try gpa.dupe(u8, value) else null,
            .outcome = if (row.get(?[]const u8, 6)) |value| try gpa.dupe(u8, value) else null,
            .git_commit = if (row.get(?[]const u8, 7)) |value| try gpa.dupe(u8, value) else null,
            .git_branch = if (row.get(?[]const u8, 8)) |value| try gpa.dupe(u8, value) else null,
            .git_dirty = dirtyFromInt(row.get(i64, 9)),
            .preview = if (row.get(?[]const u8, 10)) |value| try gpa.dupe(u8, value) else null,
        };
    }

    /// Return the most recent session that has a committed HEAD ref, or null.
    /// Caller must call `freeSessionRow(gpa, result)` when done.
    pub fn mostRecentSession(self: Index, gpa: std.mem.Allocator) !?SessionRow {
        const row = try self.db.row(
            \\select origin, session_id, head_hash, updated_at from sessions
            \\where head_hash is not null
            \\order by updated_at desc limit 1
        , .{}) orelse return null;
        defer row.deinit();
        return SessionRow{
            .origin = try gpa.dupe(u8, row.get([]const u8, 0)),
            .session_id = try gpa.dupe(u8, row.get([]const u8, 1)),
            .head_hash = if (row.get(?[]const u8, 2)) |h| try gpa.dupe(u8, h) else null,
            .updated_at = row.get(i64, 3),
        };
    }

    pub fn mostRecentStep(self: Index, gpa: std.mem.Allocator) !?TimelineRow {
        const row = try self.db.row(
            \\select hash, session_origin, session_id, turn_id, timestamp, model, git_commit, git_branch, coalesce(git_dirty, -1), preview
            \\from steps
            \\order by timestamp desc, hash desc
            \\limit 1
        , .{}) orelse return null;
        defer row.deinit();
        return .{
            .hash = try gpa.dupe(u8, row.get([]const u8, 0)),
            .origin = try gpa.dupe(u8, row.get([]const u8, 1)),
            .session_id = try gpa.dupe(u8, row.get([]const u8, 2)),
            .turn_id = try gpa.dupe(u8, row.get([]const u8, 3)),
            .timestamp = row.get(i64, 4),
            .model = if (row.get(?[]const u8, 5)) |model| try gpa.dupe(u8, model) else null,
            .git_commit = if (row.get(?[]const u8, 6)) |commit| try gpa.dupe(u8, commit) else null,
            .git_branch = if (row.get(?[]const u8, 7)) |branch| try gpa.dupe(u8, branch) else null,
            .git_dirty = dirtyFromInt(row.get(i64, 8)),
            .preview = if (row.get(?[]const u8, 9)) |preview| try gpa.dupe(u8, preview) else null,
        };
    }

    pub fn listStepsByGitCommit(self: Index, gpa: std.mem.Allocator, commit: []const u8) ![]const TimelineRow {
        var list: std.ArrayList(TimelineRow) = .empty;
        errdefer {
            for (list.items) |row| freeTimelineRow(gpa, row);
            list.deinit(gpa);
        }

        var rs = try self.db.rows(
            \\select hash, session_origin, session_id, turn_id, timestamp, model, git_commit, git_branch, coalesce(git_dirty, -1), preview
            \\from steps
            \\where git_commit = ?
            \\order by timestamp asc, hash asc
        , .{commit});
        defer rs.deinit();

        while (rs.next()) |row| {
            try list.append(gpa, .{
                .hash = try gpa.dupe(u8, row.get([]const u8, 0)),
                .origin = try gpa.dupe(u8, row.get([]const u8, 1)),
                .session_id = try gpa.dupe(u8, row.get([]const u8, 2)),
                .turn_id = try gpa.dupe(u8, row.get([]const u8, 3)),
                .timestamp = row.get(i64, 4),
                .model = if (row.get(?[]const u8, 5)) |model| try gpa.dupe(u8, model) else null,
                .git_commit = if (row.get(?[]const u8, 6)) |value| try gpa.dupe(u8, value) else null,
                .git_branch = if (row.get(?[]const u8, 7)) |value| try gpa.dupe(u8, value) else null,
                .git_dirty = dirtyFromInt(row.get(i64, 8)),
                .preview = if (row.get(?[]const u8, 9)) |preview| try gpa.dupe(u8, preview) else null,
            });
        }
        if (rs.err) |err| return err;
        return list.toOwnedSlice(gpa);
    }

    pub fn countStepsWithoutGitCommit(self: Index) !i64 {
        const row = try self.db.row("select count(*) from steps where git_commit is null", .{}) orelse return 0;
        defer row.deinit();
        return row.get(i64, 0);
    }

    /// Find a step by hash prefix. Returns null if not found; error if ambiguous.
    pub fn findStepByPrefix(self: Index, gpa: std.mem.Allocator, prefix: []const u8) !?[]const u8 {
        const pattern = try std.fmt.allocPrint(gpa, "{s}%", .{prefix});
        defer gpa.free(pattern);
        const row = try self.db.row(
            "select hash from steps where hash like ?",
            .{pattern},
        ) orelse return null;
        defer row.deinit();
        return try gpa.dupe(u8, row.get([]const u8, 0));
    }
};

fn dirtyFromInt(value: i64) ?bool {
    return switch (value) {
        0 => false,
        1 => true,
        else => null,
    };
}

// Row structs and free helpers live in sub-modules; re-exported here so all
// existing `index_mod.SessionRow` / `index_mod.freeSessionRow` callers resolve.
pub const SessionRow = @import("index/rows.zig").SessionRow;
pub const StepRow = @import("index/rows.zig").StepRow;
pub const TimelineOptions = @import("index/rows.zig").TimelineOptions;
pub const StatsOptions = @import("index/rows.zig").StatsOptions;
pub const StatsSummaryRow = @import("index/rows.zig").StatsSummaryRow;
pub const SessionStatsRow = @import("index/rows.zig").SessionStatsRow;
pub const ToolCountRow = @import("index/rows.zig").ToolCountRow;
pub const WatchOptions = @import("index/rows.zig").WatchOptions;
pub const TimelineRow = @import("index/rows.zig").TimelineRow;
pub const SearchOptions = @import("index/rows.zig").SearchOptions;
pub const SearchRow = @import("index/rows.zig").SearchRow;
pub const RecallRow = @import("index/rows.zig").RecallRow;
pub const RecallPathOptions = @import("index/rows.zig").RecallPathOptions;

pub const freeSessionRow = @import("index/free.zig").freeSessionRow;
pub const freeStepRow = @import("index/free.zig").freeStepRow;
pub const freeTimelineRow = @import("index/free.zig").freeTimelineRow;
pub const freeRecallRow = @import("index/free.zig").freeRecallRow;
pub const freeRecallRows = @import("index/free.zig").freeRecallRows;
pub const freeSessionRows = @import("index/free.zig").freeSessionRows;
pub const freeStepRows = @import("index/free.zig").freeStepRows;
pub const freeTimelineRows = @import("index/free.zig").freeTimelineRows;
pub const freeSessionStatsRow = @import("index/free.zig").freeSessionStatsRow;
pub const freeSessionStatsRows = @import("index/free.zig").freeSessionStatsRows;
pub const freeToolCountRow = @import("index/free.zig").freeToolCountRow;
pub const freeToolCountRows = @import("index/free.zig").freeToolCountRows;
pub const freeSearchRow = @import("index/free.zig").freeSearchRow;
pub const freeSearchRows = @import("index/free.zig").freeSearchRows;

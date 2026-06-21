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

/// A session row returned by index queries.
pub const SessionRow = struct {
    origin: []const u8,
    session_id: []const u8,
    head_hash: ?[]const u8,
    updated_at: i64,
};

/// A step row returned by index queries.
pub const StepRow = struct {
    hash: []const u8,
    turn_id: []const u8,
    parent_hash: ?[]const u8,
    tree_hash: []const u8,
    timestamp: i64,
    model: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
};

pub const TimelineOptions = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    limit: usize,
};

pub const StatsOptions = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub const StatsSummaryRow = struct {
    session_count: i64 = 0,
    step_count: i64 = 0,
    turn_count: i64 = 0,
    first_timestamp: ?i64 = null,
    last_timestamp: ?i64 = null,
};

pub const SessionStatsRow = struct {
    origin: []const u8,
    session_id: []const u8,
    step_count: i64,
    turn_count: i64,
    first_timestamp: ?i64,
    last_timestamp: ?i64,
};

pub const ToolCountRow = struct {
    tool_name: []const u8,
    count: i64,
};

pub const WatchOptions = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since_ms: ?i64 = null,
    after_rowid: i64,
    limit: usize,
};

pub const TimelineRow = struct {
    rowid: i64 = 0,
    hash: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    timestamp: i64,
    model: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
    preview: ?[]const u8 = null,
};

pub const SearchOptions = struct {
    match_query: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    limit: usize,
    context_tokens: usize,
};

pub const SearchRow = struct {
    entry_kind: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    step_hash: []const u8,
    timestamp: i64,
    label: []const u8,
    snippet: []const u8,
};

pub const RecallRow = struct {
    hash: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    timestamp: i64,
    model: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
    preview: ?[]const u8 = null,
};

pub const RecallPathOptions = struct {
    path: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    outcome: ?[]const u8 = null,
    limit: usize,
};

pub fn freeSessionRow(gpa: std.mem.Allocator, r: SessionRow) void {
    gpa.free(r.origin);
    gpa.free(r.session_id);
    if (r.head_hash) |h| gpa.free(h);
}

pub fn freeStepRow(gpa: std.mem.Allocator, r: StepRow) void {
    gpa.free(r.hash);
    gpa.free(r.turn_id);
    if (r.parent_hash) |p| gpa.free(p);
    gpa.free(r.tree_hash);
    if (r.model) |value| gpa.free(value);
    if (r.git_commit) |value| gpa.free(value);
    if (r.git_branch) |value| gpa.free(value);
}

pub fn freeTimelineRow(gpa: std.mem.Allocator, row: TimelineRow) void {
    gpa.free(row.hash);
    gpa.free(row.origin);
    gpa.free(row.session_id);
    gpa.free(row.turn_id);
    if (row.model) |value| gpa.free(value);
    if (row.git_commit) |value| gpa.free(value);
    if (row.git_branch) |value| gpa.free(value);
    if (row.preview) |value| gpa.free(value);
}

pub fn freeRecallRow(gpa: std.mem.Allocator, row: RecallRow) void {
    gpa.free(row.hash);
    gpa.free(row.origin);
    gpa.free(row.session_id);
    gpa.free(row.turn_id);
    if (row.model) |value| gpa.free(value);
    if (row.outcome) |value| gpa.free(value);
    if (row.git_commit) |value| gpa.free(value);
    if (row.git_branch) |value| gpa.free(value);
    if (row.preview) |value| gpa.free(value);
}

pub fn freeRecallRows(gpa: std.mem.Allocator, rows: []const RecallRow) void {
    for (rows) |row| freeRecallRow(gpa, row);
    gpa.free(rows);
}

pub fn freeSessionRows(gpa: std.mem.Allocator, rows: []const SessionRow) void {
    for (rows) |r| freeSessionRow(gpa, r);
    gpa.free(rows);
}

pub fn freeStepRows(gpa: std.mem.Allocator, rows: []const StepRow) void {
    for (rows) |r| freeStepRow(gpa, r);
    gpa.free(rows);
}

pub fn freeTimelineRows(gpa: std.mem.Allocator, rows: []const TimelineRow) void {
    for (rows) |row| freeTimelineRow(gpa, row);
    gpa.free(rows);
}

pub fn freeSessionStatsRow(gpa: std.mem.Allocator, row: SessionStatsRow) void {
    gpa.free(row.origin);
    gpa.free(row.session_id);
}

pub fn freeSessionStatsRows(gpa: std.mem.Allocator, rows: []const SessionStatsRow) void {
    for (rows) |row| freeSessionStatsRow(gpa, row);
    gpa.free(rows);
}

pub fn freeToolCountRow(gpa: std.mem.Allocator, row: ToolCountRow) void {
    gpa.free(row.tool_name);
}

pub fn freeToolCountRows(gpa: std.mem.Allocator, rows: []const ToolCountRow) void {
    for (rows) |row| freeToolCountRow(gpa, row);
    gpa.free(rows);
}

pub fn freeSearchRow(gpa: std.mem.Allocator, row: SearchRow) void {
    gpa.free(row.entry_kind);
    gpa.free(row.origin);
    gpa.free(row.session_id);
    gpa.free(row.turn_id);
    gpa.free(row.step_hash);
    gpa.free(row.label);
    gpa.free(row.snippet);
}

pub fn freeSearchRows(gpa: std.mem.Allocator, rows: []const SearchRow) void {
    for (rows) |row| freeSearchRow(gpa, row);
    gpa.free(rows);
}

test "index open and migrate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    // Applying migrations twice should be idempotent.
    try idx.migrate();
}

test "index migrate creates query-path indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    const session_idx = try idx.db.row(
        "select 1 from sqlite_master where type='index' and name='sessions_updated_at_desc'",
        .{},
    );
    try std.testing.expect(session_idx != null);
    defer session_idx.?.deinit();

    const step_idx = try idx.db.row(
        "select 1 from sqlite_master where type='index' and name='steps_session_timestamp'",
        .{},
    );
    try std.testing.expect(step_idx != null);
    defer step_idx.?.deinit();

    const meta_tbl = try idx.db.row(
        "select 1 from sqlite_master where type='table' and name='meta'",
        .{},
    );
    try std.testing.expect(meta_tbl != null);
    defer meta_tbl.?.deinit();

    const objects_tbl = try idx.db.row(
        "select 1 from sqlite_master where type='table' and name='objects'",
        .{},
    );
    try std.testing.expect(objects_tbl != null);
    defer objects_tbl.?.deinit();

    const packed_objects_tbl = try idx.db.row(
        "select 1 from sqlite_master where type='table' and name='packed_objects'",
        .{},
    );
    try std.testing.expect(packed_objects_tbl != null);
    defer packed_objects_tbl.?.deinit();

    const user_ver = try idx.db.row("pragma user_version", .{});
    try std.testing.expect(user_ver != null);
    defer user_ver.?.deinit();
    try std.testing.expectEqual(@as(i64, 12), user_ver.?.get(i64, 0));
}

test "index upsertSession and insertStep" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.upsertSession("origin", "s1", null);
    try idx.insertStep("a" ** 64, "origin", "s1", "t1", null, "b" ** 64, 1000, "gpt-5-codex", null, null, null, null, "hello preview");

    // The preview column round-trips through insertStep and is returned by the
    // list-view query, so callers can render without re-reading the step blob.
    const timeline_rows = try idx.listRecentSteps(gpa, .{ .limit = 10 });
    defer freeTimelineRows(gpa, timeline_rows);
    try std.testing.expectEqual(@as(usize, 1), timeline_rows.len);
    try std.testing.expect(timeline_rows[0].preview != null);
    try std.testing.expectEqualStrings("hello preview", timeline_rows[0].preview.?);

    // Upsert should update head_hash.
    try idx.upsertSession("origin", "s1", "c" ** 64);

    const row = try idx.db.row("select head_hash from sessions where origin=? and session_id=?", .{ "origin", "s1" });
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqualStrings("c" ** 64, row.?.get([]const u8, 0));

    const step_row = try idx.db.row(
        "select model, git_commit, git_branch, git_dirty from steps where hash=?",
        .{"a" ** 64},
    );
    try std.testing.expect(step_row != null);
    defer step_row.?.deinit();
    try std.testing.expectEqualStrings("gpt-5-codex", step_row.?.get([]const u8, 0));
    try std.testing.expect(step_row.?.get(?[]const u8, 1) == null);
    try std.testing.expect(step_row.?.get(?[]const u8, 2) == null);
    try std.testing.expect(step_row.?.get(?i64, 3) == null);
}

test "blame_maps insert and query helpers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    const step_a = "a" ** 64;
    const step_b = "b" ** 64;
    const blame_a = "1" ** 64;
    const blame_b = "2" ** 64;
    const blob_a = "3" ** 64;
    const blob_b = "4" ** 64;

    try idx.insertBlameMap("file.txt", step_a, blame_a, blob_a, "claude", "s1", 100);
    try idx.insertBlameMap("file.txt", step_b, blame_b, blob_b, "codex", "s2", 200);

    // Latest is the row with the greatest timestamp.
    const latest = (try idx.queryLatestBlame("file.txt")).?;
    try std.testing.expectEqualStrings(blame_b, latest.blame_hash[0..]);

    // As-of an earlier step resolves to the earlier row.
    const as_of = (try idx.queryBlameAtStep("file.txt", 100, step_a)).?;
    try std.testing.expectEqualStrings(blame_a, as_of.blame_hash[0..]);

    // Step metadata is recoverable for attribution rendering.
    const meta = (try idx.queryStepMeta(std.testing.allocator, step_b)).?;
    defer std.testing.allocator.free(meta.origin);
    try std.testing.expectEqualStrings("codex", meta.origin);
    try std.testing.expectEqual(@as(i64, 200), meta.timestamp);

    // Reachable blame hashes are collected for gc marking.
    var hashes: std.ArrayList([64]u8) = .empty;
    defer hashes.deinit(std.testing.allocator);
    try idx.collectBlameHashes(std.testing.allocator, &hashes);
    try std.testing.expectEqual(@as(usize, 2), hashes.items.len);

    try idx.clearBlameMaps();
    try std.testing.expect((try idx.queryLatestBlame("file.txt")) == null);
}

test "insertStep is idempotent for duplicate turn ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.upsertSession("origin", "s1", null);
    try idx.insertStep("a" ** 64, "origin", "s1", "t1", null, "b" ** 64, 1000, null, null, null, null, null, null);
    try idx.insertStep("c" ** 64, "origin", "s1", "t1", "a" ** 64, "d" ** 64, 1001, null, null, null, null, null, null);

    const count_row = try idx.db.row(
        "select count(*) from steps where session_origin=? and session_id=? and turn_id=?",
        .{ "origin", "s1", "t1" },
    );
    try std.testing.expect(count_row != null);
    defer count_row.?.deinit();
    try std.testing.expectEqual(@as(i64, 1), count_row.?.get(i64, 0));

    const hash_row = try idx.db.row(
        "select hash from steps where session_origin=? and session_id=? and turn_id=?",
        .{ "origin", "s1", "t1" },
    );
    try std.testing.expect(hash_row != null);
    defer hash_row.?.deinit();
    try std.testing.expectEqualStrings("a" ** 64, hash_row.?.get([]const u8, 0));
}

test "index truncate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.upsertSession("origin", "s1", null);
    try idx.insertStep("a" ** 64, "origin", "s1", "t1", null, "b" ** 64, 1000, null, null, null, null, null, null);
    try idx.insertObject("a" ** 64, "step", 123);
    try idx.truncate();

    const row = try idx.db.row("select count(*) from steps", .{});
    defer row.?.deinit();
    try std.testing.expectEqual(@as(i64, 0), row.?.get(i64, 0));

    const objects_row = try idx.db.row("select count(*) from objects", .{});
    defer objects_row.?.deinit();
    try std.testing.expectEqual(@as(i64, 0), objects_row.?.get(i64, 0));

    const search_row = try idx.db.row("select count(*) from search_entries", .{});
    defer search_row.?.deinit();
    try std.testing.expectEqual(@as(i64, 0), search_row.?.get(i64, 0));
}

test "truncate clears meta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.metaSet("session::s1::last_ref_hash", "abc");
    try idx.truncate();

    const value = try idx.metaGet(gpa, "session::s1::last_ref_hash");
    try std.testing.expect(value == null);
    if (value) |v| gpa.free(v);
}

test "index meta round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.metaSet("k", "v1");
    try idx.metaSet("k", "v2");

    const value = try idx.metaGet(gpa, "k");
    try std.testing.expect(value != null);
    defer gpa.free(value.?);
    try std.testing.expectEqualStrings("v2", value.?);

    try idx.metaDelete("k");
    const missing = try idx.metaGet(gpa, "k");
    try std.testing.expect(missing == null);
}

test "watch cursor queries rows in insertion order with filters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.upsertSession("codex", "s1", null);
    try idx.upsertSession("codex", "s2", null);
    try idx.insertStep("a" ** 64, "codex", "s1", "t1", null, "b" ** 64, 1000, null, null, null, null, null, null);
    try idx.insertStep("c" ** 64, "codex", "s2", "t1", null, "d" ** 64, 1100, null, null, null, null, null, null);
    try idx.insertStep("e" ** 64, "codex", "s1", "t2", "a" ** 64, "f" ** 64, 900, null, null, null, null, null, null);

    const rows = try idx.listStepsAfterCursor(gpa, .{
        .origin = "codex",
        .session_id = "s1",
        .after_rowid = 0,
        .limit = 10,
    });
    defer freeTimelineRows(gpa, rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("a" ** 64, rows[0].hash);
    try std.testing.expectEqualStrings("e" ** 64, rows[1].hash);
    try std.testing.expect(rows[0].rowid < rows[1].rowid);

    const late_rows = try idx.listStepsAfterCursor(gpa, .{
        .origin = "codex",
        .session_id = "s1",
        .after_rowid = rows[0].rowid,
        .limit = 10,
    });
    defer freeTimelineRows(gpa, late_rows);

    try std.testing.expectEqual(@as(usize, 1), late_rows.len);
    try std.testing.expectEqualStrings("e" ** 64, late_rows[0].hash);

    const latest = try idx.latestWatchRowid(.{
        .origin = "codex",
        .session_id = "s1",
        .after_rowid = 0,
        .limit = 10,
    });
    try std.testing.expectEqual(rows[1].rowid, latest.?);

    const since_rows = try idx.listStepsAfterCursor(gpa, .{
        .origin = "codex",
        .session_id = "s1",
        .since_ms = 950,
        .after_rowid = 0,
        .limit = 10,
    });
    defer freeTimelineRows(gpa, since_rows);

    try std.testing.expectEqual(@as(usize, 1), since_rows.len);
    try std.testing.expectEqualStrings("a" ** 64, since_rows[0].hash);
}

test "stats aggregate queries count sessions turns tools and bounded steps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.upsertSession("codex", "s1", "b" ** 64);
    try idx.upsertSession("claude", "s2", "c" ** 64);
    try idx.insertStep("a" ** 64, "codex", "s1", "t1", null, "1" ** 64, 1000, null, null, null, null, null, null);
    try idx.insertStep("b" ** 64, "codex", "s1", "t2", "a" ** 64, "2" ** 64, 1200, null, null, null, null, null, null);
    try idx.insertStep("c" ** 64, "claude", "s2", "t1", null, "3" ** 64, 1100, null, null, null, null, null, null);
    try idx.insertToolCall("a" ** 64, 0, "Read", "{}", null);
    try idx.insertToolCall("b" ** 64, 0, "Bash", "{}", "ok");
    try idx.insertToolCall("c" ** 64, 0, "Bash", "{}", "ok");

    const summary = try idx.statsSummary(.{});
    try std.testing.expectEqual(@as(i64, 2), summary.session_count);
    try std.testing.expectEqual(@as(i64, 3), summary.step_count);
    try std.testing.expectEqual(@as(i64, 3), summary.turn_count);
    try std.testing.expectEqual(@as(i64, 1000), summary.first_timestamp.?);
    try std.testing.expectEqual(@as(i64, 1200), summary.last_timestamp.?);

    const scoped = try idx.statsSummary(.{ .origin = "codex", .session_id = "s1" });
    try std.testing.expectEqual(@as(i64, 1), scoped.session_count);
    try std.testing.expectEqual(@as(i64, 2), scoped.step_count);
    try std.testing.expectEqual(@as(i64, 2), scoped.turn_count);

    const sessions = try idx.listSessionStats(gpa, .{});
    defer freeSessionStatsRows(gpa, sessions);
    try std.testing.expectEqual(@as(usize, 2), sessions.len);

    const tools = try idx.listToolCounts(gpa, .{}, 10);
    defer freeToolCountRows(gpa, tools);
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    try std.testing.expectEqualStrings("Bash", tools[0].tool_name);
    try std.testing.expectEqual(@as(i64, 2), tools[0].count);
    try std.testing.expectEqualStrings("Read", tools[1].tool_name);
    try std.testing.expectEqual(@as(i64, 1), tools[1].count);

    const bounded = try idx.listStatsSteps(gpa, .{}, 2);
    defer freeStepRows(gpa, bounded);
    try std.testing.expectEqual(@as(usize, 2), bounded.len);
    try std.testing.expectEqualStrings("a" ** 64, bounded[0].hash);
    try std.testing.expectEqualStrings("c" ** 64, bounded[1].hash);
}

test "index object lookup and completeness marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.insertObject("aa" ++ ("0" ** 62), "blob", 10);
    try idx.insertObject("aa" ++ ("1" ** 62), "tree", 20);
    try idx.insertObject("bb" ++ ("2" ** 62), "step", 30);

    const aa_matches = try idx.lookupObjectPrefix("aa");
    try std.testing.expectEqual(@as(usize, 2), aa_matches.count);
    try std.testing.expectEqualStrings("aa" ++ ("0" ** 62), &aa_matches.hashes[0]);
    try std.testing.expectEqualStrings("aa" ++ ("1" ** 62), &aa_matches.hashes[1]);

    const bb_matches = try idx.lookupObjectPrefix("bb");
    try std.testing.expectEqual(@as(usize, 1), bb_matches.count);
    try std.testing.expectEqualStrings("bb" ++ ("2" ** 62), &bb_matches.hashes[0]);

    try std.testing.expectEqual(@as(i64, 3), try idx.countObjects());
    try std.testing.expect(try idx.hasObject("bb" ++ ("2" ** 62)));

    try std.testing.expect((try idx.getObjectsComplete()) == null);
    try idx.setObjectsComplete(true);
    try std.testing.expectEqual(true, (try idx.getObjectsComplete()).?);
    try idx.setObjectsComplete(false);
    try std.testing.expectEqual(false, (try idx.getObjectsComplete()).?);
}

test "index search entries stay deduplicated and searchable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();
    try idx.migrate();

    try idx.upsertSession("claude", "session-1", null);
    try idx.insertStep("a" ** 64, "claude", "session-1", "turn-1", null, "b" ** 64, 1_700_000_000_000, null, null, "f" ** 40, "main", true, null);
    try idx.insertMessage("a" ** 64, 0, "user", "factorial debugging");
    try idx.insertMessage("a" ** 64, 0, "user", "factorial debugging");
    try idx.insertToolCall("a" ** 64, 1, "Bash", "{\"command\":\"echo factorial\"}", "factorial result");
    try idx.insertToolCall("a" ** 64, 1, "Bash", "{\"command\":\"echo factorial\"}", "factorial result");

    const rows = try idx.searchEntries(gpa, .{
        .match_query = "\"factorial\"",
        .limit = 10,
        .context_tokens = 8,
    });
    defer freeSearchRows(gpa, rows);

    try std.testing.expectEqual(@as(usize, 3), rows.len);

    const count_row = try idx.db.row("select count(*) from search_entries", .{});
    defer count_row.?.deinit();
    try std.testing.expectEqual(@as(i64, 3), count_row.?.get(i64, 0));
}

test "migration 6 backfills search entries for existing indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    var db_path_buf: [std.fs.max_path_bytes + 12]u8 = undefined;
    const db_path = try std.fmt.bufPrintZ(&db_path_buf, "{s}/index.db", .{path_buf[0..n]});

    const idx = try Index.open(db_path);
    defer idx.close();

    try idx.db.execNoArgs(
        \\create table schema_migrations (
        \\  version    integer primary key,
        \\  applied_at integer not null default (unixepoch())
        \\)
    );
    try idx.db.execNoArgs(
        \\create table sessions (
        \\  origin     text not null,
        \\  session_id text not null,
        \\  head_hash  text,
        \\  updated_at integer not null default (unixepoch()),
        \\  primary key (origin, session_id)
        \\)
    );
    try idx.db.execNoArgs(
        \\create table steps (
        \\  hash           text primary key,
        \\  session_origin text not null,
        \\  session_id     text not null,
        \\  turn_id        text not null,
        \\  parent_hash    text,
        \\  tree_hash      text not null,
        \\  timestamp      integer not null
        \\)
    );
    try idx.db.execNoArgs(
        \\create table messages (
        \\  id         integer primary key,
        \\  step_hash  text not null,
        \\  role       text not null,
        \\  content    text not null,
        \\  seq        integer not null default 0
        \\)
    );
    try idx.db.execNoArgs(
        \\create table tool_calls (
        \\  id         integer primary key,
        \\  step_hash  text not null,
        \\  tool_name  text not null,
        \\  args       text not null,
        \\  result     text,
        \\  seq        integer not null default 0
        \\)
    );
    try idx.db.execNoArgs(
        \\create table meta (
        \\  key   text primary key,
        \\  value text not null
        \\)
    );
    try idx.db.execNoArgs(
        \\create table objects (
        \\  hash       text primary key,
        \\  kind       text not null,
        \\  size       integer not null,
        \\  created_at integer not null default (unixepoch())
        \\)
    );
    try idx.db.exec("insert into schema_migrations (version) values (?)", .{@as(i64, 5)});
    try idx.db.execNoArgs("pragma user_version = 5");

    try idx.db.exec(
        "insert into sessions (origin, session_id, head_hash) values (?, ?, ?)",
        .{ "claude", "session-legacy", "f" ** 64 },
    );
    try idx.db.exec(
        "insert into steps (hash, session_origin, session_id, turn_id, parent_hash, tree_hash, timestamp) values (?, ?, ?, ?, ?, ?, ?)",
        .{ "a" ** 64, "claude", "session-legacy", "turn-1", null, "b" ** 64, @as(i64, 1_700_000_000_000) },
    );
    try idx.db.exec(
        "insert into messages (step_hash, role, content, seq) values (?, ?, ?, ?)",
        .{ "a" ** 64, "user", "legacy factorial prompt", @as(i64, 0) },
    );
    try idx.db.exec(
        "insert into tool_calls (step_hash, tool_name, args, result, seq) values (?, ?, ?, ?, ?)",
        .{ "a" ** 64, "Bash", "{\"command\":\"echo factorial\"}", "factorial", @as(i64, 1) },
    );

    try idx.migrate();

    const rows = try idx.searchEntries(gpa, .{
        .match_query = "\"factorial\"",
        .limit = 10,
        .context_tokens = 8,
    });
    defer freeSearchRows(gpa, rows);

    try std.testing.expectEqual(@as(usize, 3), rows.len);
}

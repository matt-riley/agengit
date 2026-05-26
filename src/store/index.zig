const std = @import("std");
const zqlite = @import("zqlite");

/// SQLite-backed index for fast session and step queries.
pub const Index = struct {
    db: zqlite.Conn,

    pub const current_schema_version: i64 = 7;
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
    ) !void {
        try self.db.exec(
            \\insert or ignore into steps
            \\  (hash, session_origin, session_id, turn_id, parent_hash, tree_hash, timestamp)
            \\values (?, ?, ?, ?, ?, ?, ?)
        , .{ hash, session_origin, session_id, turn_id, parent_hash, tree_hash, timestamp });
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
        try self.db.execNoArgs("delete from packed_objects");
        try self.db.execNoArgs("delete from objects");
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
            \\select hash, turn_id, parent_hash, tree_hash, timestamp
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
}

pub fn freeSessionRows(gpa: std.mem.Allocator, rows: []const SessionRow) void {
    for (rows) |r| freeSessionRow(gpa, r);
    gpa.free(rows);
}

pub fn freeStepRows(gpa: std.mem.Allocator, rows: []const StepRow) void {
    for (rows) |r| freeStepRow(gpa, r);
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
    try std.testing.expectEqual(@as(i64, 7), user_ver.?.get(i64, 0));
}

test "index upsertSession and insertStep" {
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
    try idx.insertStep("a" ** 64, "origin", "s1", "t1", null, "b" ** 64, 1000);

    // Upsert should update head_hash.
    try idx.upsertSession("origin", "s1", "c" ** 64);

    const row = try idx.db.row("select head_hash from sessions where origin=? and session_id=?", .{ "origin", "s1" });
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqualStrings("c" ** 64, row.?.get([]const u8, 0));
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
    try idx.insertStep("a" ** 64, "origin", "s1", "t1", null, "b" ** 64, 1000);
    try idx.insertStep("c" ** 64, "origin", "s1", "t1", "a" ** 64, "d" ** 64, 1001);

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
    try idx.insertStep("a" ** 64, "origin", "s1", "t1", null, "b" ** 64, 1000);
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
    try idx.insertStep("a" ** 64, "claude", "session-1", "turn-1", null, "b" ** 64, 1_700_000_000_000);
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

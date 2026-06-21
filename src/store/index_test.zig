const std = @import("std");
const index_mod = @import("index.zig");

const Index = index_mod.Index;
const freeTimelineRows = index_mod.freeTimelineRows;
const freeSessionStatsRows = index_mod.freeSessionStatsRows;
const freeToolCountRows = index_mod.freeToolCountRows;
const freeStepRows = index_mod.freeStepRows;
const freeSearchRows = index_mod.freeSearchRows;

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
    try std.testing.expectEqual(@as(i64, 13), user_ver.?.get(i64, 0));
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

test "index queryStepMetaBatch resolves and falls back" {
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

    const step_a = "a" ** 64;
    const step_b = "b" ** 64;
    const step_c = "c" ** 64; // known only via blame_maps fallback
    const step_x = "x" ** 64; // absent everywhere

    try idx.insertStep(step_a, "origin", "s1", "t1", null, "o" ** 64, 1000, "gpt-5-codex", null, null, null, null, null);
    try idx.insertStep(step_b, "origin", "s1", "t2", step_a, "p" ** 64, 2000, null, null, null, null, null, null);

    // step_c has no steps row; only a blame_maps entry.
    try idx.insertBlameMap("file.txt", step_c, "1" ** 64, "3" ** 64, "claude", "s2", 300);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const hashes = [_][]const u8{ step_a, step_b, step_c, step_x };
    var map = try idx.queryStepMetaBatch(arena, &hashes);
    defer map.deinit();

    const meta_a = map.get(step_a).?;
    try std.testing.expectEqualStrings("origin", meta_a.origin);
    try std.testing.expect(meta_a.model != null);
    try std.testing.expectEqualStrings("gpt-5-codex", meta_a.model.?);
    try std.testing.expectEqual(@as(i64, 1000), meta_a.timestamp);

    const meta_b = map.get(step_b).?;
    try std.testing.expectEqualStrings("origin", meta_b.origin);
    try std.testing.expect(meta_b.model == null);
    try std.testing.expectEqual(@as(i64, 2000), meta_b.timestamp);

    const meta_c = map.get(step_c).?;
    try std.testing.expectEqualStrings("claude", meta_c.origin);
    try std.testing.expect(meta_c.model == null);
    try std.testing.expectEqual(@as(i64, 300), meta_c.timestamp);

    try std.testing.expect(map.get(step_x) == null);
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

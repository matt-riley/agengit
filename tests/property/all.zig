const std = @import("std");
const test_support = @import("test_support");

const Recorder = test_support.Recorder;
const SessionMeta = test_support.SessionMeta;
const reindex_mod = test_support.reindex;
const store_mod = test_support.store;

const total_turns = 1000;

const CanonicalIndex = struct {
    objects: []u8,
    sessions: []u8,
    steps: []u8,
    messages: []u8,
    tool_calls: []u8,
    meta: []u8,
    evaluations: []u8,

    fn deinit(self: *CanonicalIndex, gpa: std.mem.Allocator) void {
        gpa.free(self.objects);
        gpa.free(self.sessions);
        gpa.free(self.steps);
        gpa.free(self.messages);
        gpa.free(self.tool_calls);
        gpa.free(self.meta);
        gpa.free(self.evaluations);
        self.* = undefined;
    }

    fn expectEqual(self: CanonicalIndex, other: CanonicalIndex) !void {
        try std.testing.expectEqualStrings(self.objects, other.objects);
        try std.testing.expectEqualStrings(self.sessions, other.sessions);
        try std.testing.expectEqualStrings(self.steps, other.steps);
        try std.testing.expectEqualStrings(self.messages, other.messages);
        try std.testing.expectEqualStrings(self.tool_calls, other.tool_calls);
        try std.testing.expectEqualStrings(self.meta, other.meta);
        try std.testing.expectEqualStrings(self.evaluations, other.evaluations);
    }
};

test "property/reindex roundtrip preserves canonical index state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try tmp.dir.createDirPath(io, ".agit");
    try tmp.dir.createDirPath(io, "workspace");

    var recorder = try Recorder.open(io, tmp.dir, gpa);
    defer recorder.deinit(io);

    var prng = std.Random.DefaultPrng.init(0xdecafbad12345678);
    const random = prng.random();

    const metas = [_]SessionMeta{
        .{ .origin = "claude", .session_id = "property-claude" },
        .{ .origin = "codex", .session_id = "property-codex" },
        .{ .origin = "gemini", .session_id = "property-gemini" },
    };

    for (0..total_turns) |turn_index| {
        const session_index = if (turn_index < metas.len) turn_index else random.uintLessThan(usize, metas.len);
        const meta = metas[session_index];

        try recorder.upsertSession(meta);
        try writeWorkspaceFile(io, tmp.dir, session_index, turn_index, random.int(u32));

        var turn_id_buf: [64]u8 = undefined;
        const turn_id = try std.fmt.bufPrint(&turn_id_buf, "{s}-turn-{d}", .{
            meta.session_id,
            turn_index,
        });

        var prompt_buf: [160]u8 = undefined;
        const prompt = try std.fmt.bufPrint(&prompt_buf, "prompt/{s}/{d}/{d}", .{
            meta.origin,
            session_index,
            random.int(u32),
        });
        try recorder.recordUserPrompt(io, meta, turn_id, .{ .content = prompt });

        const tool_count = random.uintAtMost(u8, 3);
        for (0..tool_count) |tool_index| {
            var tool_name_buf: [48]u8 = undefined;
            const tool_name = try std.fmt.bufPrint(&tool_name_buf, "tool-{d}", .{tool_index});
            var args_buf: [128]u8 = undefined;
            const args = try std.fmt.bufPrint(&args_buf, "{{\"turn\":{d},\"tool\":{d},\"rand\":{d}}}", .{
                turn_index,
                tool_index,
                random.int(u32),
            });
            var result_buf: [128]u8 = undefined;
            const result = if ((tool_index + turn_index) % 2 == 0)
                try std.fmt.bufPrint(&result_buf, "result-{d}-{d}", .{ turn_index, random.int(u16) })
            else
                null;

            try recorder.recordToolUse(io, meta, turn_id, .{
                .tool_name = tool_name,
                .args = args,
                .result = result,
            });
        }

        var assistant_buf: [160]u8 = undefined;
        const assistant = try std.fmt.bufPrint(&assistant_buf, "assistant/{s}/{d}/{d}", .{
            meta.origin,
            turn_index,
            random.int(u32),
        });
        try recorder.recordAssistantAndFinalize(io, meta, turn_id, .{ .content = assistant }, &.{});
    }

    var store = try store_mod.Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    var before = try captureCanonicalIndex(gpa, &store);
    defer before.deinit(gpa);

    try store.index.truncate();
    const rebuilt = try reindex_mod.reindex(io, gpa, &store);
    try std.testing.expectEqual(@as(usize, metas.len), rebuilt.sessions);
    try std.testing.expect(rebuilt.steps >= total_turns);

    var after = try captureCanonicalIndex(gpa, &store);
    defer after.deinit(gpa);

    try before.expectEqual(after);
}

fn writeWorkspaceFile(
    io: std.Io,
    repo_dir: std.Io.Dir,
    session_index: usize,
    turn_index: usize,
    random_value: u32,
) !void {
    const rel_dir = try std.fmt.allocPrint(std.testing.allocator, "workspace/session-{d}", .{session_index});
    defer std.testing.allocator.free(rel_dir);
    try repo_dir.createDirPath(io, rel_dir);

    const rel_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/turn-{d}.txt", .{
        rel_dir,
        turn_index % 5,
    });
    defer std.testing.allocator.free(rel_path);
    var file = try repo_dir.createFile(io, rel_path, .{ .truncate = true });
    defer file.close(io);

    var content_buf: [160]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf, "session={d} turn={d} random={d}\n", .{
        session_index,
        turn_index,
        random_value,
    });
    try file.writeStreamingAll(io, content);
}

fn captureCanonicalIndex(gpa: std.mem.Allocator, store: *store_mod.Store) !CanonicalIndex {
    return .{
        .objects = try captureObjects(gpa, store),
        .sessions = try captureSessions(gpa, store),
        .steps = try captureSteps(gpa, store),
        .messages = try captureMessages(gpa, store),
        .tool_calls = try captureToolCalls(gpa, store),
        .meta = try captureMeta(gpa, store),
        .evaluations = try captureEvaluations(gpa, store),
    };
}

fn captureObjects(gpa: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var rows = try store.index.db.rows(
        "select hash, kind, size from objects order by hash",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try aw.writer.print("{s}\t{s}\t{d}\n", .{
            row.get([]const u8, 0),
            row.get([]const u8, 1),
            row.get(i64, 2),
        });
    }
    if (rows.err) |err| return err;
    return try gpa.dupe(u8, aw.writer.buffered());
}

fn captureSessions(gpa: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var rows = try store.index.db.rows(
        "select origin, session_id, coalesce(head_hash, '') from sessions order by origin, session_id",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try aw.writer.print("{s}\t{s}\t{s}\n", .{
            row.get([]const u8, 0),
            row.get([]const u8, 1),
            row.get([]const u8, 2),
        });
    }
    if (rows.err) |err| return err;
    return try gpa.dupe(u8, aw.writer.buffered());
}

fn captureSteps(gpa: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var rows = try store.index.db.rows(
        "select hash, session_origin, session_id, turn_id, coalesce(parent_hash, ''), tree_hash, timestamp from steps order by session_origin, session_id, timestamp, hash",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try aw.writer.print("{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{
            row.get([]const u8, 0),
            row.get([]const u8, 1),
            row.get([]const u8, 2),
            row.get([]const u8, 3),
            row.get([]const u8, 4),
            row.get([]const u8, 5),
            row.get(i64, 6),
        });
    }
    if (rows.err) |err| return err;
    return try gpa.dupe(u8, aw.writer.buffered());
}

fn captureMessages(gpa: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var rows = try store.index.db.rows(
        "select step_hash, seq, role, content from messages order by step_hash, seq",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try aw.writer.print("{s}\t{d}\t{s}\t{s}\n", .{
            row.get([]const u8, 0),
            row.get(i64, 1),
            row.get([]const u8, 2),
            row.get([]const u8, 3),
        });
    }
    if (rows.err) |err| return err;
    return try gpa.dupe(u8, aw.writer.buffered());
}

fn captureToolCalls(gpa: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var rows = try store.index.db.rows(
        "select step_hash, seq, tool_name, args, coalesce(result, '') from tool_calls order by step_hash, seq",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try aw.writer.print("{s}\t{d}\t{s}\t{s}\t{s}\n", .{
            row.get([]const u8, 0),
            row.get(i64, 1),
            row.get([]const u8, 2),
            row.get([]const u8, 3),
            row.get([]const u8, 4),
        });
    }
    if (rows.err) |err| return err;
    return try gpa.dupe(u8, aw.writer.buffered());
}

fn captureMeta(gpa: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var rows = try store.index.db.rows(
        "select key, value from meta where key not like 'metrics.%' order by key",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try aw.writer.print("{s}\t{s}\n", .{
            row.get([]const u8, 0),
            row.get([]const u8, 1),
        });
    }
    if (rows.err) |err| return err;
    return try gpa.dupe(u8, aw.writer.buffered());
}

fn captureEvaluations(gpa: std.mem.Allocator, store: *store_mod.Store) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var rows = try store.index.db.rows(
        "select hash, scope_type, scope_key, classification, captured_evidence_hash, evaluated_at from evaluations order by hash",
        .{},
    );
    defer rows.deinit();
    while (rows.next()) |row| {
        try aw.writer.print("{s}\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{
            row.get([]const u8, 0),
            row.get([]const u8, 1),
            row.get([]const u8, 2),
            row.get([]const u8, 3),
            row.get([]const u8, 4),
            row.get(i64, 5),
        });
    }
    if (rows.err) |err| return err;
    return try gpa.dupe(u8, aw.writer.buffered());
}

const std = @import("std");
const store_mod = @import("../store/store.zig");
const object = @import("../store/object.zig");
const hash_mod = @import("../store/hash.zig");

// Phase 2: rebuild the SQLite index from the object store.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = iter;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    // Open the store from cwd.
    const cwd = std.Io.Dir.cwd();
    var store = store_mod.Store.open(io, cwd, gpa) catch |err| {
        try stdout.interface.print("error: could not open store: {s}\n", .{@errorName(err)});
        try stdout.flush();
        std.process.exit(1);
    };
    defer store.deinit(io);

    // Wipe and rebuild.
    try store.index.truncate();
    const rebuilt = try reindex(io, gpa, &store);

    try stdout.interface.print("reindexed: {d} session(s), {d} step(s)\n", .{
        rebuilt.sessions,
        rebuilt.steps,
    });
    try stdout.flush();
}

const ReindexStats = struct {
    sessions: usize,
    steps: usize,
};

pub fn reindex(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store) !ReindexStats {
    var stats = ReindexStats{ .sessions = 0, .steps = 0 };

    // Walk every object in the store and parse those with type=="step".
    var obj_dir = store.root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return stats, // empty store
        else => return err,
    };
    defer obj_dir.close(io);

    var walker = try obj_dir.walk(gpa);
    defer walker.deinit();

    // Track which sessions we have already created to count them correctly.
    var seen_sessions = std.StringHashMap(void).init(gpa);
    defer {
        var it = seen_sessions.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen_sessions.deinit();
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path.len != 65) continue;

        var hex_buf: [64]u8 = undefined;
        @memcpy(hex_buf[0..2], entry.path[0..2]);
        @memcpy(hex_buf[2..64], entry.path[3..65]);

        const h = hash_mod.Hash.fromHex(&hex_buf) catch continue;
        const h_hex = h.toHex();

        // Read object and try to parse as Step.
        const data = object.read(io, store.root, gpa, h) catch continue;
        defer gpa.free(data);

        // Cheap pre-check: the JSON must contain "\"type\":\"step\"".
        if (std.mem.indexOf(u8, data, "\"type\":\"step\"") == null) continue;

        const parsed = std.json.parseFromSlice(
            object.Step,
            gpa,
            data,
            .{ .allocate = .alloc_always },
        ) catch continue;
        defer parsed.deinit();

        const step = parsed.value;
        if (!std.mem.eql(u8, step.type, "step")) continue;

        // Ensure the session row exists with a null HEAD for now;
        // we will fix up the real HEAD after the full walk.
        const sess_key = try std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ step.origin, step.session_id });
        if (!seen_sessions.contains(sess_key)) {
            try store.index.upsertSession(step.origin, step.session_id, null);
            try seen_sessions.put(sess_key, {});
            stats.sessions += 1;
        } else {
            gpa.free(sess_key);
        }

        try store.index.insertStep(
            &h_hex,
            step.origin,
            step.session_id,
            step.turn_id,
            step.parent,
            step.tree,
            step.timestamp,
        );

        // Rebuild messages and tool_calls from the embedded step data.
        for (step.messages, 0..) |msg, i| {
            try store.index.insertMessage(&h_hex, @intCast(i), msg.role, msg.content);
        }
        for (step.tool_calls, 0..) |tc, i| {
            try store.index.insertToolCall(&h_hex, @intCast(i), tc.tool_name, tc.args, tc.result);
        }

        stats.steps += 1;
    }

    // Fix up HEAD hashes from the actual ref files now that all steps are indexed.
    var sess_it = seen_sessions.keyIterator();
    while (sess_it.next()) |k| {
        const key = k.*;
        const sep = std.mem.indexOfScalar(u8, key, 0) orelse continue;
        const origin = key[0..sep];
        const session_id = key[sep + 1 ..];

        if (try store.readRef(io, gpa, origin, session_id)) |h| {
            const head_hex = h.toHex();
            try store.index.upsertSession(origin, session_id, &head_hex);
        }
    }

    return stats;
}

test "reindex repairs missing rows from objects and refs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var store = try store_mod.Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const step = object.Step{
        .parent = null,
        .tree = "a" ** 64,
        .session_id = "sess-1",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
        .messages = &.{.{ .role = "assistant", .content = "ok" }},
        .tool_calls = &.{},
    };

    const h = try store.writeStep(io, gpa, step);
    const ok = try store.casRef(io, gpa, step.origin, step.session_id, null, h, &step);
    try std.testing.expect(ok);

    try store.index.truncate();

    const stats = try reindex(io, gpa, &store);
    try std.testing.expectEqual(@as(usize, 1), stats.sessions);
    try std.testing.expectEqual(@as(usize, 1), stats.steps);

    const h_hex = h.toHex();
    const row = try store.index.db.row(
        "select head_hash from sessions where origin=? and session_id=?",
        .{ step.origin, step.session_id },
    );
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqualStrings(&h_hex, row.?.get([]const u8, 0));

    const msg_row = try store.index.db.row(
        "select content from messages where step_hash=? and seq=0",
        .{&h_hex},
    );
    try std.testing.expect(msg_row != null);
    defer msg_row.?.deinit();
    try std.testing.expectEqualStrings("ok", msg_row.?.get([]const u8, 0));
}

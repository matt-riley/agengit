const std = @import("std");
const store_mod = @import("../store/store.zig");
const object = @import("../store/object.zig");
const hash_mod = @import("../store/hash.zig");
const help_mod = @import("help.zig");

pub const usage = help_mod.UsageSpec{
    .name = "reindex",
    .synopsis = "[OPTIONS]",
    .description = "Rebuild the SQLite index from object/ref truth.",
    .options = &.{
        .{ .long = "from", .value_name = "HASH", .description = "Incrementally replay steps newer than <HASH> that are reachable from session refs." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "rebuild entire index", .command = "" },
        .{ .description = "incrementally update from a hash", .command = "--from abc123def" },
    },
};

const Options = struct {
    from: ?hash_mod.Hash = null,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => {
            try stdout.flush();
            return;
        },
        else => return err,
    };

    // Open the store from cwd.
    const cwd = std.Io.Dir.cwd();
    var store = store_mod.Store.open(io, cwd, gpa) catch |err| {
        try stdout.interface.print("error: could not open store: {s}\n", .{@errorName(err)});
        try stdout.flush();
        std.process.exit(1);
    };
    defer store.deinit(io);

    if (options.from) |from_hash| {
        const rebuilt = try reindexFrom(io, gpa, &store, from_hash);
        const from_hex = from_hash.toHex();
        try stdout.interface.print(
            "reindexed from {s}: {d} session(s), {d} step(s)\n",
            .{ &from_hex, rebuilt.sessions, rebuilt.steps },
        );
    } else {
        // Wipe and rebuild.
        try store.index.truncate();
        const rebuilt = try reindex(io, gpa, &store);
        try stdout.interface.print("reindexed: {d} session(s), {d} step(s)\n", .{
            rebuilt.sessions,
            rebuilt.steps,
        });
    }
    try stdout.flush();
}

const ReindexStats = struct {
    sessions: usize,
    steps: usize,
};

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !Options {
    var options: Options = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--from")) {
            const value = iter.next() orelse {
                try stdout.interface.writeAll("error: --from requires a 64-character hash\n\n");
                try help_mod.renderUsage(stdout, usage);
                try stdout.flush();
                return error.InvalidArgument;
            };
            options.from = hash_mod.Hash.fromHex(value) catch {
                try stdout.interface.print("error: invalid --from hash '{s}'\n\n", .{value});
                try help_mod.renderUsage(stdout, usage);
                try stdout.flush();
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            return error.HelpShown;
        } else {
            try stdout.interface.print("error: unknown option '{s}'\n\n", .{arg});
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.InvalidArgument;
        }
    }
    return options;
}

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
            try writeMetaForSession(gpa, store, origin, session_id, h);
        }
    }

    return stats;
}

pub fn reindexFrom(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    from_hash: hash_mod.Hash,
) !ReindexStats {
    var stats = ReindexStats{ .sessions = 0, .steps = 0 };
    const sessions = try collectRefSessions(io, gpa, store);
    defer freeSessions(gpa, sessions);

    for (sessions) |sess| {
        const head = try store.readRef(io, gpa, sess.origin, sess.session_id);
        if (head == null) continue;
        if (!try replayFromHead(io, gpa, store, sess.origin, sess.session_id, from_hash, head.?, &stats)) continue;
        stats.sessions += 1;
    }
    return stats;
}

const SessionIdent = struct {
    origin: []u8,
    session_id: []u8,
};

fn collectRefSessions(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store) ![]const SessionIdent {
    var list: std.ArrayList(SessionIdent) = .empty;
    errdefer {
        for (list.items) |sess| {
            gpa.free(sess.origin);
            gpa.free(sess.session_id);
        }
        list.deinit(gpa);
    }

    var refs_dir = store.root.openDir(io, "refs/sessions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return list.toOwnedSlice(gpa),
        else => return err,
    };
    defer refs_dir.close(io);

    var walker = try refs_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const sep = std.mem.indexOfScalar(u8, entry.path, '/') orelse continue;
        const origin = try decodeHexAlloc(gpa, entry.path[0..sep]);
        errdefer gpa.free(origin);
        const session_id = try decodeHexAlloc(gpa, entry.path[sep + 1 ..]);
        errdefer gpa.free(session_id);
        try list.append(gpa, .{ .origin = origin, .session_id = session_id });
    }
    return list.toOwnedSlice(gpa);
}

fn decodeHexAlloc(gpa: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len == 0 or (hex.len % 2) != 0) return error.InvalidRefPath;
    const out = try gpa.alloc(u8, hex.len / 2);
    errdefer gpa.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn freeSessions(gpa: std.mem.Allocator, sessions: []const SessionIdent) void {
    for (sessions) |sess| {
        gpa.free(sess.origin);
        gpa.free(sess.session_id);
    }
    gpa.free(sessions);
}

fn replayFromHead(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    origin: []const u8,
    session_id: []const u8,
    from_hash: hash_mod.Hash,
    head_hash: hash_mod.Hash,
    stats: *ReindexStats,
) !bool {
    var chain: std.ArrayList(hash_mod.Hash) = .empty;
    defer chain.deinit(gpa);

    var cursor: ?hash_mod.Hash = head_hash;
    var found_from = false;
    while (cursor) |h| {
        if (h.eql(from_hash)) {
            found_from = true;
            break;
        }
        try chain.append(gpa, h);
        var parsed = try store.readStep(io, gpa, h);
        defer parsed.deinit();
        cursor = if (parsed.value.parent) |parent_hex| try hash_mod.Hash.fromHex(parent_hex) else null;
    }

    if (!found_from) return false;
    if (chain.items.len == 0) return true;

    try store.index.db.transaction();
    errdefer store.index.db.rollback();

    var i = chain.items.len;
    while (i > 0) : (i -= 1) {
        const h = chain.items[i - 1];
        const h_hex = h.toHex();
        var parsed = try store.readStep(io, gpa, h);
        defer parsed.deinit();
        const step = parsed.value;
        try store.index.insertStep(
            &h_hex,
            step.origin,
            step.session_id,
            step.turn_id,
            step.parent,
            step.tree,
            step.timestamp,
        );
        for (step.messages, 0..) |msg, seq| {
            try store.index.insertMessage(&h_hex, @intCast(seq), msg.role, msg.content);
        }
        for (step.tool_calls, 0..) |tc, seq| {
            try store.index.insertToolCall(&h_hex, @intCast(seq), tc.tool_name, tc.args, tc.result);
        }
        stats.steps += 1;
    }

    const head_hex = head_hash.toHex();
    try store.index.upsertSession(origin, session_id, &head_hex);
    try writeMetaForSession(gpa, store, origin, session_id, head_hash);
    try store.index.db.commit();
    return true;
}

fn writeMetaForSession(
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    origin: []const u8,
    session_id: []const u8,
    tip_hash: hash_mod.Hash,
) !void {
    const tip_hex = tip_hash.toHex();
    const count = try store.index.countSessionSteps(origin, session_id);
    var seq_buf: [32]u8 = undefined;
    const seq = try std.fmt.bufPrint(&seq_buf, "{d}", .{count});

    const ref_key = try std.fmt.allocPrint(gpa, "session::{x}:{x}::last_ref_hash", .{ origin, session_id });
    defer gpa.free(ref_key);
    const step_key = try std.fmt.allocPrint(gpa, "session::{x}:{x}::last_step_hash", .{ origin, session_id });
    defer gpa.free(step_key);
    const seq_key = try std.fmt.allocPrint(gpa, "session::{x}:{x}::last_step_seq", .{ origin, session_id });
    defer gpa.free(seq_key);

    try store.index.metaSet(ref_key, &tip_hex);
    try store.index.metaSet(step_key, &tip_hex);
    try store.index.metaSet(seq_key, seq);
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
    const ok = try store.casRef(io, gpa, step.origin, step.session_id, null, h, &step, step.messages, step.tool_calls);
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

test "reindex --from replays newer steps reachable from refs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var store = try store_mod.Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const step1 = object.Step{
        .parent = null,
        .tree = "a" ** 64,
        .session_id = "sess-inc",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
        .messages = &.{.{ .role = "assistant", .content = "first" }},
        .tool_calls = &.{},
    };
    const h1 = try store.writeStep(io, gpa, step1);
    try std.testing.expect(try store.casRef(io, gpa, step1.origin, step1.session_id, null, h1, &step1, step1.messages, step1.tool_calls));

    const h1_hex = h1.toHex();
    const step2 = object.Step{
        .parent = &h1_hex,
        .tree = "b" ** 64,
        .session_id = "sess-inc",
        .origin = "github.com/u/r",
        .turn_id = "t2",
        .causes = &.{},
        .timestamp = 1001,
        .messages = &.{.{ .role = "assistant", .content = "second" }},
        .tool_calls = &.{},
    };
    const h2 = try store.writeStep(io, gpa, step2);
    try std.testing.expect(try store.casRef(io, gpa, step2.origin, step2.session_id, h1, h2, &step2, step2.messages, step2.tool_calls));

    const h2_hex = h2.toHex();
    try store.index.db.exec("delete from messages where step_hash=?", .{&h2_hex});
    try store.index.db.exec("delete from tool_calls where step_hash=?", .{&h2_hex});
    try store.index.db.exec("delete from steps where hash=?", .{&h2_hex});

    const stats = try reindexFrom(io, gpa, &store, h1);
    try std.testing.expectEqual(@as(usize, 1), stats.sessions);
    try std.testing.expectEqual(@as(usize, 1), stats.steps);
    try std.testing.expect(try store.index.hasStep(&h2_hex));
}

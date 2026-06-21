const std = @import("std");
const store_mod = @import("store.zig");
const file_lock = @import("../util/file_lock.zig");
const ref = @import("ref.zig");
const preview_mod = @import("preview.zig");

const Store = store_mod.Store;
const Hash = store_mod.Hash;

const SessionIdent = struct {
    origin: []const u8,
    session_id: []const u8,
};

pub fn reconcile(self: *Store, io: std.Io, gpa: std.mem.Allocator, mode: Store.ReconcileMode) !Store.ReconcileReport {
    var report: Store.ReconcileReport = .{};
    const sessions = try collectKnownSessions(self, io, gpa);
    defer freeSessionIdents(gpa, sessions);

    for (sessions) |sess| {
        report.sessions_checked += 1;
        const outcome = try reconcileSession(self, io, gpa, mode, sess.origin, sess.session_id);
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
    mode: Store.ReconcileMode,
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
        if (!try replaySessionChain(self, io, gpa, origin, session_id, null, ref_tip.?)) {
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
        if (!try replaySessionChain(self, io, gpa, origin, session_id, meta_ref, ref_tip.?)) {
            return .index_ahead;
        }
        return .repaired;
    }

    if (meta_ref == null) {
        if (mode == .dry_run) return .drifted;
        try self.updateSessionMeta(gpa, origin, session_id, ref_tip.?);
        return .repaired;
    }

    // ref_tip is set, indexed, and meta_ref is set but doesn't match ref_tip.
    // The ref file is the source of truth; update the meta to catch up.
    if (mode == .dry_run) return .drifted;
    try self.updateSessionMeta(gpa, origin, session_id, ref_tip.?);
    return .repaired;
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

    const tip_hex = tip_hash.toHex();
    try self.index.upsertSession(origin, session_id, &tip_hex);

    var i = chain.items.len;
    while (i > 0) : (i -= 1) {
        const h = chain.items[i - 1];
        const hex = h.toHex();
        const raw = self.readBlob(io, gpa, h) catch {
            return false;
        };
        defer gpa.free(raw);
        var parsed = self.readStep(io, gpa, h) catch {
            return false;
        };
        defer parsed.deinit();
        const step = parsed.value;
        try self.index.insertObject(&hex, "step", raw.len);
        const preview_str = try preview_mod.computePreviewAlloc(gpa, step);
        defer gpa.free(preview_str);
        try self.index.insertStep(
            &hex,
            step.origin,
            step.session_id,
            step.turn_id,
            step.parent,
            step.tree,
            step.timestamp,
            step.model,
            step.outcome,
            step.git_commit,
            step.git_branch,
            step.git_dirty,
            preview_str,
        );
        for (step.messages, 0..) |msg, seq| {
            try self.index.insertMessage(&hex, @intCast(seq), msg.role, msg.content);
        }
        for (step.tool_calls, 0..) |tc, seq| {
            try self.index.insertToolCall(&hex, @intCast(seq), tc.tool_name, tc.args, tc.result);
        }
    }

    try self.updateSessionMetaLocked(gpa, origin, session_id, tip_hash);
    try self.index.db.commit();
    return true;
}

fn collectKnownSessions(self: *Store, io: std.Io, gpa: std.mem.Allocator) ![]SessionIdent {
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
    defer store_mod.freeSessionRows(gpa, rows);
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

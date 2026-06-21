const std = @import("std");
const hash_mod = @import("hash.zig");
const store_mod = @import("store.zig");
const snapshot_mod = @import("snapshot.zig");
const index_mod = @import("index.zig");

pub const Hash = hash_mod.Hash;

pub const ContentSearchOptions = struct {
    query: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    limit: usize,
    context_tokens: usize,
    max_candidates: usize = 4096,
};

pub const ContentMatch = struct {
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    step_hash: []const u8,
    timestamp: i64,
    path: []const u8,
    snippet: []const u8,
};

/// Free all memory owned by a slice of ContentMatch.
pub fn freeContentMatches(gpa: std.mem.Allocator, matches: []const ContentMatch) void {
    for (matches) |m| {
        gpa.free(@constCast(m.origin));
        gpa.free(@constCast(m.session_id));
        gpa.free(@constCast(m.turn_id));
        gpa.free(@constCast(m.step_hash));
        gpa.free(@constCast(m.path));
        gpa.free(@constCast(m.snippet));
    }
    gpa.free(matches);
}

/// Search reachable blob bodies across all sessions (filtered by options).
/// Returns matches sorted by timestamp descending. Caller owns the result.
pub fn searchBlobContent(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    options: ContentSearchOptions,
) ![]const ContentMatch {
    const sessions = try store.index.listSessions(gpa);
    defer store_mod.freeSessionRows(gpa, sessions);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var matches: std.ArrayList(ContentMatch) = .empty;
    var seen_steps = std.StringHashMap(void).init(arena);
    var seen_blobs = std.StringHashMap(void).init(arena);
    var candidates_scanned: usize = 0;

    for (sessions) |session| {
        if (session.head_hash == null) continue;
        if (options.origin) |origin| {
            if (!std.mem.eql(u8, origin, session.origin)) continue;
        }
        if (options.session_id) |sid| {
            if (!std.mem.eql(u8, sid, session.session_id)) continue;
        }

        var current_hash: ?[]const u8 = session.head_hash.?;
        while (current_hash) |h| {
            if (seen_steps.contains(h)) break;
            try seen_steps.put(try arena.dupe(u8, h), {});

            const step_hash = try Hash.fromHex(h);
            var parsed_step = store.readStep(io, arena, step_hash) catch break;
            defer parsed_step.deinit();
            const step = parsed_step.value;

            if (options.since_ms) |since| {
                if (step.timestamp < since) {
                    break;
                }
            }
            if (options.until_ms_exclusive) |until| {
                if (step.timestamp >= until) {
                    current_hash = if (step.parent) |p| try arena.dupe(u8, p) else null;
                    continue;
                }
            }

            if (!seen_blobs.contains(step.tree)) {
                try seen_blobs.put(try arena.dupe(u8, step.tree), {});
                const tree_hash = try Hash.fromHex(step.tree);
                var parsed_tree = store.readTree(io, arena, tree_hash) catch {
                    current_hash = if (step.parent) |p| try arena.dupe(u8, p) else null;
                    continue;
                };
                defer parsed_tree.deinit();
                for (parsed_tree.value.entries) |entry| {
                    if (seen_blobs.contains(entry.blob)) continue;
                    try seen_blobs.put(try arena.dupe(u8, entry.blob), {});

                    if (candidates_scanned >= options.max_candidates) break;
                    candidates_scanned += 1;

                    const blob_hash = try Hash.fromHex(entry.blob);
                    const blob = store.readBlob(io, arena, blob_hash) catch continue;
                    if (snapshot_mod.isBinary(blob)) continue;
                    if (snapshot_mod.isSnapshotPlaceholder(blob)) continue;

                    if (matches.items.len >= options.limit) break;

                    if (findMatchInBlob(arena, blob, entry.path, options.query, options.context_tokens, step, h) catch null) |m| {
                        try matches.append(arena, m);
                    }
                }
            }

            if (matches.items.len >= options.limit) break;
            if (candidates_scanned >= options.max_candidates) break;

            current_hash = if (step.parent) |p| try arena.dupe(u8, p) else null;
        }
        if (matches.items.len >= options.limit) break;
        if (candidates_scanned >= options.max_candidates) break;
    }

    const result = try gpa.alloc(ContentMatch, matches.items.len);
    for (matches.items, 0..) |m, i| {
        result[i] = .{
            .origin = try gpa.dupe(u8, m.origin),
            .session_id = try gpa.dupe(u8, m.session_id),
            .turn_id = try gpa.dupe(u8, m.turn_id),
            .step_hash = try gpa.dupe(u8, m.step_hash),
            .timestamp = m.timestamp,
            .path = try gpa.dupe(u8, m.path),
            .snippet = try gpa.dupe(u8, m.snippet),
        };
    }
    return result;
}

fn findMatchInBlob(
    arena: std.mem.Allocator,
    blob: []const u8,
    path: []const u8,
    query: []const u8,
    context_tokens: usize,
    step: store_mod.Step,
    step_hash_str: []const u8,
) !?ContentMatch {
    const lower_blob = std.ascii.allocLowerString(arena, blob) catch return null;
    const lower_query = std.ascii.allocLowerString(arena, query) catch return null;
    const match_idx = std.mem.indexOf(u8, lower_blob, lower_query) orelse return null;

    const snippet = buildSnippet(arena, blob, match_idx, query.len, context_tokens, path);

    return .{
        .origin = try arena.dupe(u8, step.origin),
        .session_id = try arena.dupe(u8, step.session_id),
        .turn_id = try arena.dupe(u8, step.turn_id),
        .step_hash = try arena.dupe(u8, step_hash_str),
        .timestamp = step.timestamp,
        .path = try arena.dupe(u8, path),
        .snippet = snippet,
    };
}

fn buildSnippet(
    arena: std.mem.Allocator,
    text: []const u8,
    match_start: usize,
    match_len: usize,
    context_tokens: usize,
    path: []const u8,
) []const u8 {
    var out: std.ArrayList(u8) = .empty;

    out.appendSlice(arena, path) catch return text[match_start..@min(text.len, match_start + match_len + context_tokens)];
    out.appendSlice(arena, ": ") catch return text[match_start..@min(text.len, match_start + match_len + context_tokens)];

    const context_start = match_start -| context_tokens;
    const raw_end = @min(text.len, match_start + match_len + context_tokens);

    if (context_start > 0) {
        out.appendSlice(arena, "…") catch {};
    }

    const window = text[context_start..raw_end];
    for (window) |c| {
        if (c == '\n' or c == '\r') {
            out.append(arena, ' ') catch break;
        } else {
            out.append(arena, c) catch break;
        }
    }

    if (raw_end < text.len) {
        out.appendSlice(arena, "…") catch {};
    }

    return out.toOwnedSlice(arena) catch text[match_start..@min(text.len, match_start + match_len)];
}

test "searchBlobContent finds text in blob" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = try store_mod.Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const blob_data = "fn factorial(n: usize) usize { return if (n <= 1) 1 else n * factorial(n - 1); }";
    const blob_hash = try s.writeBlob(io, blob_data);
    const blob_hex = blob_hash.toHex();

    const tree = store_mod.Tree{
        .entries = &.{.{
            .path = "src/math.zig",
            .blob = &blob_hex,
            .mode = "file",
            .size = blob_data.len,
        }},
    };
    const tree_hash = try s.writeTree(io, gpa, tree);
    const tree_hex = tree_hash.toHex();

    const step = store_mod.Step{
        .parent = null,
        .tree = &tree_hex,
        .session_id = "sess-001",
        .origin = "test-origin",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };
    const step_hash = try s.writeStep(io, gpa, step);

    _ = try s.casRef(io, gpa, step.origin, step.session_id, null, step_hash, &step, step.messages, step.tool_calls);

    var s2 = try store_mod.Store.openExisting(io, tmp.dir, gpa);
    defer s2.deinit(io);
    _ = try s2.reconcile(io, gpa, .repair);

    const matches = try searchBlobContent(io, gpa, &s2, .{
        .query = "factorial",
        .limit = 10,
        .context_tokens = 20,
    });
    defer freeContentMatches(gpa, matches);

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("test-origin", matches[0].origin);
    try std.testing.expectEqualStrings("sess-001", matches[0].session_id);
    try std.testing.expectEqualStrings("src/math.zig", matches[0].path);
    try std.testing.expect(std.mem.indexOf(u8, matches[0].snippet, "factorial") != null);
}

test "searchBlobContent respects origin filter" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = try store_mod.Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const blob = try s.writeBlob(io, "hello world");
    const blob_hex = blob.toHex();
    const tree = store_mod.Tree{
        .entries = &.{.{
            .path = "f.txt",
            .blob = &blob_hex,
            .mode = "file",
            .size = 11,
        }},
    };
    const tree_hash = try s.writeTree(io, gpa, tree);
    const tree_hex = tree_hash.toHex();
    const step = store_mod.Step{
        .parent = null,
        .tree = &tree_hex,
        .session_id = "s1",
        .origin = "alpha",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };
    const step_hash = try s.writeStep(io, gpa, step);
    _ = try s.casRef(io, gpa, step.origin, step.session_id, null, step_hash, &step, step.messages, step.tool_calls);

    var s2 = try store_mod.Store.openExisting(io, tmp.dir, gpa);
    defer s2.deinit(io);
    _ = try s2.reconcile(io, gpa, .repair);

    const matches = try searchBlobContent(io, gpa, &s2, .{
        .query = "hello",
        .origin = "beta",
        .limit = 10,
        .context_tokens = 10,
    });
    defer freeContentMatches(gpa, matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "searchBlobContent skips metadata-only placeholder blobs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = try store_mod.Store.open(io, tmp.dir, gpa);
    defer s.deinit(io);

    const marker = snapshot_mod.metadata_only_marker ++ " path=src/secret.txt bytes=100]]\n";
    const blob = try s.writeBlob(io, marker);
    const blob_hex = blob.toHex();
    const tree = store_mod.Tree{
        .entries = &.{.{
            .path = "src/secret.txt",
            .blob = &blob_hex,
            .mode = "file",
            .size = marker.len,
        }},
    };
    const tree_hash = try s.writeTree(io, gpa, tree);
    const tree_hex = tree_hash.toHex();
    const step = store_mod.Step{
        .parent = null,
        .tree = &tree_hex,
        .session_id = "sess-meta",
        .origin = "test",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1000,
    };
    const step_hash = try s.writeStep(io, gpa, step);
    _ = try s.casRef(io, gpa, step.origin, step.session_id, null, step_hash, &step, step.messages, step.tool_calls);

    var s2 = try store_mod.Store.openExisting(io, tmp.dir, gpa);
    defer s2.deinit(io);
    _ = try s2.reconcile(io, gpa, .repair);

    const matches = try searchBlobContent(io, gpa, &s2, .{
        .query = "secret",
        .limit = 10,
        .context_tokens = 10,
    });
    defer freeContentMatches(gpa, matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

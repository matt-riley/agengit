const std = @import("std");

const fs_mod = @import("../util/fs.zig");
const file_lock_mod = @import("../util/file_lock.zig");
const hash_mod = @import("hash.zig");
const object_mod = @import("object.zig");
const pack_mod = @import("pack.zig");
const ref_mod = @import("ref.zig");
const store_mod = @import("store.zig");

pub const default_grace_period_ms: i64 = 2 * 60 * 60 * 1000;
pub const default_log_rotate_bytes: u64 = 10 * 1024 * 1024;
const active_lock_stale_after_ms: i64 = 5 * 60 * 1000;

pub const Options = struct {
    grace_period_ms: i64 = default_grace_period_ms,
    prune_before_ms: ?i64 = null,
    log_rotate_bytes: u64 = default_log_rotate_bytes,
};

pub const BusyLock = struct {
    path: []u8,
    age_ms: i64,
    pid: i64,
};

pub const Result = struct {
    busy_lock: ?BusyLock = null,
    refs_pruned: usize = 0,
    objects_pruned: usize = 0,
    object_bytes_pruned: u64 = 0,
    tmp_files_pruned: usize = 0,
    log_rotated: bool = false,
    reindex_needed: bool = false,
    reachable_objects: usize = 0,
    reachable_bytes: u64 = 0,
    total_objects_before: usize = 0,
    total_bytes_before: u64 = 0,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        if (self.busy_lock) |busy| {
            gpa.free(busy.path);
        }
        self.* = undefined;
    }
};

const DeleteCandidate = struct {
    path: []u8,
    size: u64 = 0,
};

fn freeCandidates(gpa: std.mem.Allocator, items: []const DeleteCandidate) void {
    for (items) |item| gpa.free(item.path);
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store, options: Options) !Result {
    var gc_lock = try file_lock_mod.LockFile.acquire(io, store.root, "gc.lock", .{});
    defer gc_lock.release(io);

    if (try findBusyLock(io, gpa, store.root)) |busy| {
        return .{ .busy_lock = busy };
    }

    var result: Result = .{};

    if (options.prune_before_ms) |cutoff_ms| {
        result.refs_pruned = try pruneSessionRefs(io, gpa, store, cutoff_ms);
        if (result.refs_pruned > 0) result.reindex_needed = true;
    }

    var reachable = std.AutoHashMap([hash_mod.hex_len]u8, void).init(gpa);
    defer reachable.deinit();
    try markReachable(io, gpa, store, &reachable);

    try sweepLooseObjects(io, gpa, store, options.grace_period_ms, &reachable, &result);
    try repackReachableLooseObjects(io, gpa, store, &reachable, &result);
    try cleanupTmp(io, gpa, store, options.grace_period_ms, &result);
    result.log_rotated = try maybeRotateHookErrorLog(io, store, options.log_rotate_bytes);

    return result;
}

fn findBusyLock(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir) !?BusyLock {
    var iter_dir = try root.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);

    var walker = try iter_dir.walk(gpa);
    defer walker.deinit();

    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".lock")) continue;
        if (std.mem.eql(u8, entry.path, "gc.lock")) continue;

        const stat = root.statFile(io, entry.path, .{}) catch continue;
        const age_ms: i64 = @max(0, now_ms - stat.mtime.toMilliseconds());
        if (age_ms > active_lock_stale_after_ms) continue;

        const data = root.readFileAlloc(io, entry.path, gpa, .unlimited) catch {
            return .{
                .path = try std.fmt.allocPrint(gpa, ".agit/{s}", .{entry.path}),
                .age_ms = age_ms,
                .pid = 0,
            };
        };
        defer gpa.free(data);

        const trimmed = std.mem.trim(u8, data, "\n\r ");
        var parsed = std.json.parseFromSlice(file_lock_mod.LockRecord, gpa, trimmed, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            return .{
                .path = try std.fmt.allocPrint(gpa, ".agit/{s}", .{entry.path}),
                .age_ms = age_ms,
                .pid = 0,
            };
        };
        defer parsed.deinit();

        if (parsed.value.pid > 0) {
            return .{
                .path = try std.fmt.allocPrint(gpa, ".agit/{s}", .{entry.path}),
                .age_ms = age_ms,
                .pid = parsed.value.pid,
            };
        }
    }

    return null;
}

fn pruneSessionRefs(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store, cutoff_ms: i64) !usize {
    var refs_dir = store.root.openDir(io, "refs/sessions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        else => return err,
    };
    defer refs_dir.close(io);

    var walker = try refs_dir.walk(gpa);
    defer walker.deinit();

    var deletes: std.ArrayList(DeleteCandidate) = .empty;
    defer {
        freeCandidates(gpa, deletes.items);
        deletes.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".lock")) continue;

        const data = try refs_dir.readFileAlloc(io, entry.path, gpa, .unlimited);
        defer gpa.free(data);
        const head_hash = try parseRefHash(data);

        var parsed = try store.readStep(io, gpa, head_hash);
        defer parsed.deinit();

        if (parsed.value.timestamp < cutoff_ms) {
            try deletes.append(gpa, .{
                .path = try gpa.dupe(u8, entry.path),
            });
        }
    }

    for (deletes.items) |item| {
        try refs_dir.deleteFile(io, item.path);
    }

    return deletes.items.len;
}

fn markReachable(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    reachable: *std.AutoHashMap([hash_mod.hex_len]u8, void),
) !void {
    var refs_dir = store.root.openDir(io, "refs/sessions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer refs_dir.close(io);

    var walker = try refs_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".lock")) continue;

        const data = try refs_dir.readFileAlloc(io, entry.path, gpa, .unlimited);
        defer gpa.free(data);
        const head_hash = try parseRefHash(data);
        try markStepChain(io, gpa, store, reachable, head_hash);
    }
}

fn markStepChain(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    reachable: *std.AutoHashMap([hash_mod.hex_len]u8, void),
    head_hash: hash_mod.Hash,
) !void {
    var cursor: ?hash_mod.Hash = head_hash;
    while (cursor) |current| {
        const current_hex = current.toHex();
        if (reachable.contains(current_hex)) break;
        try reachable.put(current_hex, {});

        var parsed = try store.readStep(io, gpa, current);
        defer parsed.deinit();
        try markTree(io, gpa, store, reachable, try hash_mod.Hash.fromHex(parsed.value.tree));
        cursor = if (parsed.value.parent) |parent_hex| try hash_mod.Hash.fromHex(parent_hex) else null;
    }
}

fn markTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    reachable: *std.AutoHashMap([hash_mod.hex_len]u8, void),
    tree_hash: hash_mod.Hash,
) !void {
    const tree_hex = tree_hash.toHex();
    if (reachable.contains(tree_hex)) return;
    try reachable.put(tree_hex, {});

    var parsed = try store.readTree(io, gpa, tree_hash);
    defer parsed.deinit();

    for (parsed.value.entries) |entry| {
        const blob_hash = try hash_mod.Hash.fromHex(entry.blob);
        const blob_hex = blob_hash.toHex();
        if (!reachable.contains(blob_hex)) {
            try reachable.put(blob_hex, {});
        }
    }
}

fn sweepLooseObjects(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    grace_period_ms: i64,
    reachable: *const std.AutoHashMap([hash_mod.hex_len]u8, void),
    result: *Result,
) !void {
    var obj_dir = store.root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer obj_dir.close(io);

    var walker = try obj_dir.walk(gpa);
    defer walker.deinit();

    var deletes: std.ArrayList(DeleteCandidate) = .empty;
    defer {
        freeCandidates(gpa, deletes.items);
        deletes.deinit(gpa);
    }

    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path.len != 65 or entry.path[2] != '/') continue;

        var hex_buf: [hash_mod.hex_len]u8 = undefined;
        @memcpy(hex_buf[0..2], entry.path[0..2]);
        @memcpy(hex_buf[2..64], entry.path[3..65]);
        _ = hash_mod.Hash.fromHex(&hex_buf) catch continue;

        const stat = try obj_dir.statFile(io, entry.path, .{});
        result.total_objects_before += 1;
        result.total_bytes_before += stat.size;

        if (reachable.contains(hex_buf)) {
            result.reachable_objects += 1;
            result.reachable_bytes += stat.size;
            continue;
        }

        const age_ms: i64 = @max(0, now_ms - stat.mtime.toMilliseconds());
        if (age_ms < grace_period_ms) continue;

        try deletes.append(gpa, .{
            .path = try gpa.dupe(u8, entry.path),
            .size = stat.size,
        });
    }

    for (deletes.items) |item| {
        try obj_dir.deleteFile(io, item.path);
        result.objects_pruned += 1;
        result.object_bytes_pruned += item.size;
    }

    if (result.objects_pruned > 0) result.reindex_needed = true;
}

fn cleanupTmp(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    grace_period_ms: i64,
    result: *Result,
) !void {
    var tmp_dir = store.root.openDir(io, "tmp", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer tmp_dir.close(io);

    var walker = try tmp_dir.walk(gpa);
    defer walker.deinit();

    var deletes: std.ArrayList(DeleteCandidate) = .empty;
    defer {
        freeCandidates(gpa, deletes.items);
        deletes.deinit(gpa);
    }

    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!(std.mem.endsWith(u8, entry.path, ".json") or std.mem.endsWith(u8, entry.path, ".lock"))) continue;

        const stat = try tmp_dir.statFile(io, entry.path, .{});
        const age_ms: i64 = @max(0, now_ms - stat.mtime.toMilliseconds());
        if (age_ms < grace_period_ms) continue;

        try deletes.append(gpa, .{
            .path = try gpa.dupe(u8, entry.path),
        });
    }

    for (deletes.items) |item| {
        try tmp_dir.deleteFile(io, item.path);
        result.tmp_files_pruned += 1;
    }
}

const PackCandidate = struct {
    hash: hash_mod.Hash,
    hex: [hash_mod.hex_len]u8,
    kind: pack_mod.EntryKind,
    raw: []u8,
    size: u64,
};

fn repackReachableLooseObjects(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    reachable: *const std.AutoHashMap([hash_mod.hex_len]u8, void),
    result: *Result,
) !void {
    var already_packed = std.AutoHashMap([hash_mod.hex_len]u8, void).init(gpa);
    defer already_packed.deinit();
    try collectPackedHashes(io, gpa, store, &already_packed);

    var candidates: std.ArrayList(PackCandidate) = .empty;
    defer {
        for (candidates.items) |candidate| gpa.free(candidate.raw);
        candidates.deinit(gpa);
    }

    var duplicate_deletes: std.ArrayList(DeleteCandidate) = .empty;
    defer {
        freeCandidates(gpa, duplicate_deletes.items);
        duplicate_deletes.deinit(gpa);
    }

    var obj_dir = store.root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer obj_dir.close(io);

    var walker = try obj_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.path.len != 65 or entry.path[2] != '/') continue;

        var hex_buf: [hash_mod.hex_len]u8 = undefined;
        @memcpy(hex_buf[0..2], entry.path[0..2]);
        @memcpy(hex_buf[2..], entry.path[3..]);
        const hash = hash_mod.Hash.fromHex(&hex_buf) catch continue;
        if (!reachable.contains(hex_buf)) continue;

        const stat = try obj_dir.statFile(io, entry.path, .{});
        if (already_packed.contains(hex_buf)) {
            try duplicate_deletes.append(gpa, .{
                .path = try gpa.dupe(u8, entry.path),
                .size = stat.size,
            });
            continue;
        }

        const raw = try object_mod.read(io, store.root, gpa, hash);
        errdefer gpa.free(raw);
        const kind = pack_mod.EntryKind.fromString(object_mod.detectKind(raw)) catch {
            gpa.free(raw);
            continue;
        };
        try candidates.append(gpa, .{
            .hash = hash,
            .hex = hex_buf,
            .kind = kind,
            .raw = raw,
            .size = stat.size,
        });
    }

    if (candidates.items.len == 0 and duplicate_deletes.items.len == 0) return;

    std.mem.sort(PackCandidate, candidates.items, {}, lessThanCandidate);

    if (candidates.items.len > 0) {
        var candidate_lookup = std.AutoHashMap([hash_mod.hex_len]u8, usize).init(gpa);
        defer candidate_lookup.deinit();
        for (candidates.items, 0..) |candidate, i| {
            try candidate_lookup.put(candidate.hex, i);
        }

        var raw_delta_candidates = try collectBlobDeltaCandidates(io, gpa, store, &candidate_lookup);
        defer raw_delta_candidates.deinit();

        var base_users = std.AutoHashMap([hash_mod.hex_len]u8, void).init(gpa);
        defer base_users.deinit();
        {
            var iter = raw_delta_candidates.iterator();
            while (iter.next()) |entry| {
                try base_users.put(entry.value_ptr.*, {});
            }
        }

        var accepted_deltas = std.AutoHashMap([hash_mod.hex_len]u8, [hash_mod.hex_len]u8).init(gpa);
        defer accepted_deltas.deinit();

        var iter = raw_delta_candidates.iterator();
        while (iter.next()) |entry| {
            const target_hex = entry.key_ptr.*;
            const base_hex = entry.value_ptr.*;
            const target_index = candidate_lookup.get(target_hex) orelse continue;
            const base_index = candidate_lookup.get(base_hex) orelse continue;
            if (target_index == base_index) continue;
            if (candidates.items[target_index].kind != .blob or candidates.items[base_index].kind != .blob) continue;
            if (base_users.contains(target_hex)) continue;
            if (raw_delta_candidates.contains(base_hex)) continue;
            const payload = try pack_mod.encodeDelta(gpa, candidates.items[base_index].raw, candidates.items[target_index].raw);
            defer gpa.free(payload);
            if (payload.len >= candidates.items[target_index].raw.len) continue;
            try accepted_deltas.put(target_hex, base_hex);
        }

        var planned: std.ArrayList(pack_mod.PlannedEntry) = .empty;
        defer planned.deinit(gpa);

        var planned_index = std.AutoHashMap([hash_mod.hex_len]u8, usize).init(gpa);
        defer planned_index.deinit();

        for (candidates.items) |candidate| {
            if (accepted_deltas.contains(candidate.hex)) continue;
            try planned.append(gpa, .{
                .hash = candidate.hash,
                .kind = candidate.kind,
                .raw = candidate.raw,
            });
            try planned_index.put(candidate.hex, planned.items.len - 1);
        }

        for (candidates.items) |candidate| {
            const base_hex = accepted_deltas.get(candidate.hex) orelse continue;
            const base_index = planned_index.get(base_hex) orelse continue;
            try planned.append(gpa, .{
                .hash = candidate.hash,
                .kind = candidate.kind,
                .raw = candidate.raw,
                .delta_base_index = base_index,
            });
        }

        var pack_write = try pack_mod.writePack(io, store.root, gpa, planned.items);
        defer pack_write.deinit(gpa);
        result.reindex_needed = true;

        for (candidates.items) |candidate| {
            try duplicate_deletes.append(gpa, .{
                .path = try looseObjectPath(gpa, candidate.hex),
                .size = candidate.size,
            });
        }
    }

    for (duplicate_deletes.items) |item| {
        obj_dir.deleteFile(io, item.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
    if (duplicate_deletes.items.len > 0) result.reindex_needed = true;
}

fn collectPackedHashes(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    out: *std.AutoHashMap([hash_mod.hex_len]u8, void),
) !void {
    const pack_files = try pack_mod.listPackFiles(io, store.root, gpa);
    defer pack_mod.freePackFiles(gpa, pack_files);

    for (pack_files) |pack_name| {
        const entries = try pack_mod.readPackEntries(io, store.root, gpa, pack_name);
        defer pack_mod.freeParsedEntries(gpa, entries);
        for (entries) |entry| {
            try out.put(entry.meta.hash.toHex(), {});
        }
    }
}

fn collectBlobDeltaCandidates(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    packable: *const std.AutoHashMap([hash_mod.hex_len]u8, usize),
) !std.AutoHashMap([hash_mod.hex_len]u8, [hash_mod.hex_len]u8) {
    var candidates = std.AutoHashMap([hash_mod.hex_len]u8, [hash_mod.hex_len]u8).init(gpa);
    errdefer candidates.deinit();

    var refs_dir = store.root.openDir(io, "refs/sessions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return candidates,
        else => return err,
    };
    defer refs_dir.close(io);

    var walker = try refs_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".lock")) continue;

        const raw = try refs_dir.readFileAlloc(io, entry.path, gpa, .unlimited);
        defer gpa.free(raw);
        const head_hash = try parseRefHash(raw);
        try collectSessionBlobDeltaCandidates(io, gpa, store, packable, &candidates, head_hash);
    }

    return candidates;
}

fn collectSessionBlobDeltaCandidates(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    packable: *const std.AutoHashMap([hash_mod.hex_len]u8, usize),
    candidates: *std.AutoHashMap([hash_mod.hex_len]u8, [hash_mod.hex_len]u8),
    head_hash: hash_mod.Hash,
) !void {
    var chain: std.ArrayList(hash_mod.Hash) = .empty;
    defer chain.deinit(gpa);

    var cursor: ?hash_mod.Hash = head_hash;
    while (cursor) |current| {
        try chain.append(gpa, current);
        var parsed = try store.readStep(io, gpa, current);
        defer parsed.deinit();
        cursor = if (parsed.value.parent) |parent_hex| try hash_mod.Hash.fromHex(parent_hex) else null;
    }

    var previous_paths = std.StringHashMap([hash_mod.hex_len]u8).init(gpa);
    defer freePathBlobMap(gpa, &previous_paths);
    var previous_populated = false;

    var i = chain.items.len;
    while (i > 0) : (i -= 1) {
        var parsed_step = try store.readStep(io, gpa, chain.items[i - 1]);
        defer parsed_step.deinit();
        const tree_hash = try hash_mod.Hash.fromHex(parsed_step.value.tree);
        var parsed_tree = try store.readTree(io, gpa, tree_hash);
        defer parsed_tree.deinit();

        var current_paths = std.StringHashMap([hash_mod.hex_len]u8).init(gpa);
        errdefer freePathBlobMap(gpa, &current_paths);

        for (parsed_tree.value.entries) |tree_entry| {
            const blob_hash = try hash_mod.Hash.fromHex(tree_entry.blob);
            const blob_hex = blob_hash.toHex();
            try current_paths.put(try gpa.dupe(u8, tree_entry.path), blob_hex);

            if (!previous_populated) continue;
            const prior_blob = previous_paths.get(tree_entry.path) orelse continue;
            if (std.mem.eql(u8, &prior_blob, &blob_hex)) continue;
            if (!packable.contains(blob_hex) or !packable.contains(prior_blob)) continue;
            if (candidates.contains(blob_hex)) continue;
            try candidates.put(blob_hex, prior_blob);
        }

        freePathBlobMap(gpa, &previous_paths);
        previous_paths = current_paths;
        previous_populated = true;
    }
}

fn freePathBlobMap(gpa: std.mem.Allocator, map: *std.StringHashMap([hash_mod.hex_len]u8)) void {
    var iter = map.keyIterator();
    while (iter.next()) |key| gpa.free(key.*);
    map.deinit();
}

fn looseObjectPath(gpa: std.mem.Allocator, hex: [hash_mod.hex_len]u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ hex[0..2], hex[2..] });
}

fn lessThanCandidate(_: void, a: PackCandidate, b: PackCandidate) bool {
    return std.mem.order(u8, &a.hex, &b.hex) == .lt;
}

fn maybeRotateHookErrorLog(io: std.Io, store: *store_mod.Store, rotate_after_bytes: u64) !bool {
    const stat = store.root.statFile(io, "log/hook-error.log", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.size <= rotate_after_bytes) return false;

    var log_lock = file_lock_mod.LockFile.acquire(io, store.root, "log/hook-error.log.lock", .{
        .timeout_ms = 50,
    }) catch |err| switch (err) {
        error.LockTimeout => return false,
        else => return err,
    };
    defer log_lock.release(io);

    store.root.deleteFile(io, "log/hook-error.log.1") catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try fs_mod.renameDurable(io, store.root, "log/hook-error.log", store.root, "log/hook-error.log.1");
    return true;
}

fn parseRefHash(raw: []const u8) !hash_mod.Hash {
    return hash_mod.Hash.fromHex(std.mem.trim(u8, raw, " \t\r\n"));
}

test "gc prunes unreachable objects but preserves shared history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var store = try store_mod.Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const shared_blob = try store.writeBlob(io, "shared");
    const old_blob = try store.writeBlob(io, "old-only");
    const new_blob = try store.writeBlob(io, "new-only");

    const old_tree = store_mod.Tree{ .entries = &.{
        .{ .path = "old.txt", .blob = &old_blob.toHex(), .mode = "file", .size = 8 },
        .{ .path = "shared.txt", .blob = &shared_blob.toHex(), .mode = "file", .size = 6 },
    } };
    const new_tree = store_mod.Tree{ .entries = &.{
        .{ .path = "new.txt", .blob = &new_blob.toHex(), .mode = "file", .size = 8 },
        .{ .path = "shared.txt", .blob = &shared_blob.toHex(), .mode = "file", .size = 6 },
    } };

    const old_tree_hash = try store.writeTree(io, gpa, old_tree);
    const new_tree_hash = try store.writeTree(io, gpa, new_tree);

    const old_step = store_mod.Step{
        .parent = null,
        .tree = &old_tree_hash.toHex(),
        .session_id = "old-session",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1_000,
    };
    const old_step_hash = try store.writeStep(io, gpa, old_step);
    try std.testing.expect(try store.casRef(io, gpa, old_step.origin, old_step.session_id, null, old_step_hash, &old_step, old_step.messages, old_step.tool_calls));

    const new_step = store_mod.Step{
        .parent = null,
        .tree = &new_tree_hash.toHex(),
        .session_id = "new-session",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 2_000,
    };
    const new_step_hash = try store.writeStep(io, gpa, new_step);
    try std.testing.expect(try store.casRef(io, gpa, new_step.origin, new_step.session_id, null, new_step_hash, &new_step, new_step.messages, new_step.tool_calls));

    const old_ref_path = try ref_mod.buildRefPath(gpa, old_step.origin, old_step.session_id);
    defer gpa.free(old_ref_path);
    try store.root.deleteFile(io, old_ref_path);

    var result = try run(io, gpa, &store, .{ .grace_period_ms = 0 });
    defer result.deinit(gpa);

    try std.testing.expect(result.busy_lock == null);
    try std.testing.expect(result.objects_pruned > 0);

    const shared_back = try store.readBlob(io, gpa, shared_blob);
    defer gpa.free(shared_back);
    const new_back = try store.readBlob(io, gpa, new_blob);
    defer gpa.free(new_back);
    try std.testing.expectError(error.FileNotFound, store.readBlob(io, gpa, old_blob));
    try std.testing.expectError(error.FileNotFound, store.readTree(io, gpa, old_tree_hash));
    try std.testing.expectError(error.FileNotFound, store.readStep(io, gpa, old_step_hash));
}

test "gc prunes refs older than cutoff and cleans stale tmp files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var store = try store_mod.Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const blob = try store.writeBlob(io, "content");
    const tree = store_mod.Tree{ .entries = &.{
        .{ .path = "file.txt", .blob = &blob.toHex(), .mode = "file", .size = 7 },
    } };
    const tree_hash = try store.writeTree(io, gpa, tree);
    const step = store_mod.Step{
        .parent = null,
        .tree = &tree_hash.toHex(),
        .session_id = "old-session",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1_000,
    };
    const step_hash = try store.writeStep(io, gpa, step);
    try std.testing.expect(try store.casRef(io, gpa, step.origin, step.session_id, null, step_hash, &step, step.messages, step.tool_calls));

    try store.root.createDirPath(io, "tmp/turns");
    var stale = try store.root.createFile(io, "tmp/turns/stale.json", .{});
    defer stale.close(io);
    try stale.writeStreamingAll(io, "{}");

    var result = try run(io, gpa, &store, .{
        .grace_period_ms = 0,
        .prune_before_ms = 2_000,
    });
    defer result.deinit(gpa);

    try std.testing.expect(result.refs_pruned == 1);
    try std.testing.expect(result.tmp_files_pruned == 1);
}

test "gc packs repeated blob revisions into a smaller pack while preserving reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var store = try store_mod.Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const base_blob_text = try buildLargeBlobText(gpa, false);
    defer gpa.free(base_blob_text);
    const changed_blob_text = try buildLargeBlobText(gpa, true);
    defer gpa.free(changed_blob_text);

    const base_blob = try store.writeBlob(io, base_blob_text);
    const changed_blob = try store.writeBlob(io, changed_blob_text);

    const base_tree = store_mod.Tree{ .entries = &.{
        .{ .path = "src/large.txt", .blob = &base_blob.toHex(), .mode = "file", .size = base_blob_text.len },
    } };
    const changed_tree = store_mod.Tree{ .entries = &.{
        .{ .path = "src/large.txt", .blob = &changed_blob.toHex(), .mode = "file", .size = changed_blob_text.len },
    } };

    const base_tree_hash = try store.writeTree(io, gpa, base_tree);
    const changed_tree_hash = try store.writeTree(io, gpa, changed_tree);

    const step1 = store_mod.Step{
        .parent = null,
        .tree = &base_tree_hash.toHex(),
        .session_id = "pack-session",
        .origin = "github.com/u/r",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 1_000,
    };
    const step1_hash = try store.writeStep(io, gpa, step1);
    try std.testing.expect(try store.casRef(io, gpa, step1.origin, step1.session_id, null, step1_hash, &step1, step1.messages, step1.tool_calls));

    const step2 = store_mod.Step{
        .parent = &step1_hash.toHex(),
        .tree = &changed_tree_hash.toHex(),
        .session_id = "pack-session",
        .origin = "github.com/u/r",
        .turn_id = "t2",
        .causes = &.{},
        .timestamp = 2_000,
    };
    const step2_hash = try store.writeStep(io, gpa, step2);
    try std.testing.expect(try store.casRef(io, gpa, step2.origin, step2.session_id, step1_hash, step2_hash, &step2, step2.messages, step2.tool_calls));

    var result = try run(io, gpa, &store, .{ .grace_period_ms = 0 });
    defer result.deinit(gpa);
    try std.testing.expect(result.reindex_needed);

    const pack_files = try pack_mod.listPackFiles(io, store.root, gpa);
    defer pack_mod.freePackFiles(gpa, pack_files);
    try std.testing.expectEqual(@as(usize, 1), pack_files.len);

    const pack_path = try std.fmt.allocPrint(gpa, "objects/pack/{s}", .{pack_files[0]});
    defer gpa.free(pack_path);
    const pack_stat = try store.root.statFile(io, pack_path, .{});
    try std.testing.expect(pack_stat.size < base_blob_text.len + changed_blob_text.len);

    const base_back = try store.readBlob(io, gpa, base_blob);
    defer gpa.free(base_back);
    const changed_back = try store.readBlob(io, gpa, changed_blob);
    defer gpa.free(changed_back);
    try std.testing.expectEqualStrings(base_blob_text, base_back);
    try std.testing.expectEqualStrings(changed_blob_text, changed_back);

    const base_path = try looseObjectPath(gpa, base_blob.toHex());
    defer gpa.free(base_path);
    try std.testing.expectError(error.FileNotFound, store.root.statFile(io, base_path, .{}));
}

fn buildLargeBlobText(gpa: std.mem.Allocator, changed: bool) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const line = if (changed and i == 10_000)
            try std.fmt.allocPrint(gpa, "line-{d}: changed payload for pack delta coverage\n", .{i})
        else
            try std.fmt.allocPrint(gpa, "line-{d}: stable payload for pack delta coverage\n", .{i});
        defer gpa.free(line);
        try buf.appendSlice(gpa, line);
    }
    return try buf.toOwnedSlice(gpa);
}

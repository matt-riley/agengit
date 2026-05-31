const std = @import("std");
const zqlite = @import("zqlite");

const blame_mod = @import("blame.zig");
const file_lock_mod = @import("../util/file_lock.zig");
const hash_mod = @import("hash.zig");
const index_mod = @import("index.zig");
const object_mod = @import("object.zig");
const pack_mod = @import("pack.zig");
const ref_mod = @import("ref.zig");

pub const Severity = enum {
    ok,
    info,
    warn,
    @"error",
};

pub const Finding = struct {
    code: []const u8,
    severity: Severity,
    message: []const u8,
    hint: ?[]const u8 = null,
    path: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

pub const RepairStats = struct {
    sessions: usize = 0,
    steps: usize = 0,
};

pub const Stats = struct {
    object_files: usize = 0,
    ref_files: usize = 0,
    reachable_sessions: usize = 0,
    reachable_steps: usize = 0,
    warnings: usize = 0,
    errors: usize = 0,
};

pub const ScanResult = struct {
    arena: std.heap.ArenaAllocator,
    findings: []const Finding,
    stats: Stats,

    pub fn deinit(self: *ScanResult) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn hasErrors(self: *const ScanResult) bool {
        return self.stats.errors > 0;
    }

    pub fn hasWarnings(self: *const ScanResult) bool {
        return self.stats.warnings > 0;
    }
};

const expected_lock_stale_after_ms: i64 = 5 * 60 * 1000;

const ObjectKind = enum {
    blob,
    tree,
    step,
    blame,
    unknown_json,
    invalid,
};

const ObjectRecord = struct {
    kind: ObjectKind,
    cache_kind: []const u8,
    path: []const u8,
    raw_size: usize,
    declared_type: ?[]const u8 = null,
    referenced: bool = false,
    tree_blob_refs: []const [hash_mod.hex_len]u8 = &.{},
    blame_step_refs: []const [hash_mod.hex_len]u8 = &.{},
    step: ?StepInfo = null,
};

const StepInfo = struct {
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    parent: ?[hash_mod.hex_len]u8,
    tree: [hash_mod.hex_len]u8,
    timestamp: i64,
    message_count: usize,
    tool_call_count: usize,
};

const SessionSummary = struct {
    origin: []const u8,
    session_id: []const u8,
    head_hash: [hash_mod.hex_len]u8,
};

const CategoryState = struct {
    object_integrity_issue: bool = false,
    reachability_issue: bool = false,
    ref_issue: bool = false,
    index_issue: bool = false,
    mutable_issue: bool = false,
};

pub fn scan(io: std.Io, gpa: std.mem.Allocator, store_root: std.Io.Dir, store_abs_path: []const u8) !ScanResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var findings: std.ArrayList(Finding) = .empty;
    var categories: CategoryState = .{};
    var stats: Stats = .{};

    var objects = std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord).init(aa);
    var sessions = std.StringHashMap(SessionSummary).init(aa);
    var reachable_steps = std.AutoHashMap([hash_mod.hex_len]u8, StepInfo).init(aa);

    try scanObjects(io, gpa, aa, store_root, &objects, &findings, &stats, &categories);
    try scanPackedObjects(io, gpa, aa, store_root, &objects, &findings, &stats, &categories);
    try validateReachability(aa, &objects, &findings, &stats, &categories);
    try scanRefs(io, gpa, aa, store_root, &objects, &sessions, &reachable_steps, &findings, &stats, &categories);
    try warnOnUnknownLooseObjects(aa, &objects, &findings, &stats, &categories);
    try inspectIndex(io, aa, store_abs_path, &objects, &sessions, &reachable_steps, &findings, &stats, &categories);
    try inspectMutableArea(io, gpa, aa, store_root, &findings, &stats, &categories);
    appendOkFindings(aa, &findings, &stats, &categories);

    return .{
        .arena = arena,
        .findings = try findings.toOwnedSlice(aa),
        .stats = stats,
    };
}

fn scanObjects(
    io: std.Io,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    store_root: std.Io.Dir,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var objects_dir = store_root.openDir(io, "objects", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer objects_dir.close(io);

    var walker = try objects_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        stats.object_files += 1;

        if (entry.path.len != 65 or entry.path[2] != '/') {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_path_invalid",
                .message = try std.fmt.allocPrint(aa, "Loose object path has an invalid shard layout: {s}.", .{entry.path}),
                .path = try std.fmt.allocPrint(aa, ".agit/objects/{s}", .{entry.path}),
            });
            continue;
        }

        var hex_buf: [hash_mod.hex_len]u8 = undefined;
        @memcpy(hex_buf[0..2], entry.path[0..2]);
        @memcpy(hex_buf[2..], entry.path[3..]);
        _ = hash_mod.Hash.fromHex(&hex_buf) catch {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_path_invalid",
                .message = try std.fmt.allocPrint(aa, "Loose object path is not valid lowercase hex: {s}.", .{entry.path}),
                .path = try std.fmt.allocPrint(aa, ".agit/objects/{s}", .{entry.path}),
            });
            continue;
        };

        const object_path = try std.fmt.allocPrint(aa, ".agit/objects/{s}", .{entry.path});
        const raw = objects_dir.readFileAlloc(io, entry.path, gpa, .unlimited) catch |err| {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_read_failed",
                .message = try std.fmt.allocPrint(aa, "Loose object could not be read: {s}.", .{entry.path}),
                .hint = @errorName(err),
                .path = object_path,
                .hash = try aa.dupe(u8, &hex_buf),
            });
            continue;
        };
        defer gpa.free(raw);

        const actual = hash_mod.Hash.ofBytes(raw).toHex();
        if (!std.mem.eql(u8, &actual, &hex_buf)) {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_hash_mismatch",
                .message = "Loose object content does not match its BLAKE3 path.",
                .path = object_path,
                .hash = try aa.dupe(u8, &hex_buf),
            });
        }

        const record = try inspectObjectData(aa, raw, object_path, &hex_buf, findings, stats, categories);
        try objects.put(hex_buf, record);
    }
}

fn scanPackedObjects(
    io: std.Io,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    store_root: std.Io.Dir,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    const pack_files = try pack_mod.listPackFiles(io, store_root, gpa);
    defer pack_mod.freePackFiles(gpa, pack_files);

    for (pack_files) |pack_name| {
        const entries = pack_mod.readPackEntries(io, store_root, gpa, pack_name) catch |err| {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "pack_read_failed",
                .message = try std.fmt.allocPrint(aa, "Packed object file could not be parsed: {s}.", .{pack_name}),
                .hint = @errorName(err),
                .path = try std.fmt.allocPrint(aa, ".agit/objects/pack/{s}", .{pack_name}),
            });
            continue;
        };
        defer pack_mod.freeParsedEntries(gpa, entries);

        for (entries) |entry| {
            stats.object_files += 1;
            const hex = entry.meta.hash.toHex();
            const object_path = try std.fmt.allocPrint(aa, ".agit/objects/pack/{s}@{d}", .{
                pack_name,
                entry.meta.offset,
            });
            const record = try inspectObjectData(aa, entry.raw, object_path, &hex, findings, stats, categories);
            try objects.put(hex, record);
        }
    }
}

fn inspectObjectData(
    aa: std.mem.Allocator,
    raw: []const u8,
    object_path: []const u8,
    object_hash: *const [hash_mod.hex_len]u8,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !ObjectRecord {
    const detected_kind = object_mod.detectKind(raw);

    if (std.mem.eql(u8, detected_kind, "tree")) {
        var parsed = std.json.parseFromSlice(object_mod.Tree, aa, raw, .{ .allocate = .alloc_always }) catch {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_schema_invalid",
                .message = "Tree object does not match the supported schema.",
                .path = object_path,
                .hash = try aa.dupe(u8, object_hash),
            });
            return .{
                .kind = .invalid,
                .cache_kind = "tree",
                .path = object_path,
                .raw_size = raw.len,
                .declared_type = "tree",
            };
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.type, "tree")) {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_schema_invalid",
                .message = "Tree object has an invalid type tag.",
                .path = object_path,
                .hash = try aa.dupe(u8, object_hash),
            });
            return .{
                .kind = .invalid,
                .cache_kind = "tree",
                .path = object_path,
                .raw_size = raw.len,
                .declared_type = "tree",
            };
        }

        var refs: std.ArrayList([hash_mod.hex_len]u8) = .empty;
        for (parsed.value.entries) |entry| {
            try refs.append(aa, try parseHexHash(entry.blob));
        }

        return .{
            .kind = .tree,
            .cache_kind = "tree",
            .path = object_path,
            .raw_size = raw.len,
            .tree_blob_refs = try refs.toOwnedSlice(aa),
        };
    }

    if (std.mem.eql(u8, detected_kind, "step")) {
        var parsed = std.json.parseFromSlice(object_mod.Step, aa, raw, .{ .allocate = .alloc_always }) catch {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_schema_invalid",
                .message = "Step object does not match the supported schema.",
                .path = object_path,
                .hash = try aa.dupe(u8, object_hash),
            });
            return .{
                .kind = .invalid,
                .cache_kind = "step",
                .path = object_path,
                .raw_size = raw.len,
                .declared_type = "step",
            };
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.type, "step")) {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_schema_invalid",
                .message = "Step object has an invalid type tag.",
                .path = object_path,
                .hash = try aa.dupe(u8, object_hash),
            });
            return .{
                .kind = .invalid,
                .cache_kind = "step",
                .path = object_path,
                .raw_size = raw.len,
                .declared_type = "step",
            };
        }

        const parent = if (parsed.value.parent) |parent_hex| try parseHexHash(parent_hex) else null;
        return .{
            .kind = .step,
            .cache_kind = "step",
            .path = object_path,
            .raw_size = raw.len,
            .step = .{
                .origin = try aa.dupe(u8, parsed.value.origin),
                .session_id = try aa.dupe(u8, parsed.value.session_id),
                .turn_id = try aa.dupe(u8, parsed.value.turn_id),
                .parent = parent,
                .tree = try parseHexHash(parsed.value.tree),
                .timestamp = parsed.value.timestamp,
                .message_count = parsed.value.messages.len,
                .tool_call_count = parsed.value.tool_calls.len,
            },
        };
    }

    if (std.mem.eql(u8, detected_kind, "blame")) {
        var parsed = std.json.parseFromSlice(blame_mod.BlameMap, aa, raw, .{ .allocate = .alloc_always }) catch {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_schema_invalid",
                .message = "Blame object does not match the supported schema.",
                .path = object_path,
                .hash = try aa.dupe(u8, object_hash),
            });
            return .{
                .kind = .invalid,
                .cache_kind = "blame",
                .path = object_path,
                .raw_size = raw.len,
                .declared_type = "blame",
            };
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.type, "blame")) {
            try appendFinding(aa, findings, stats, categories, .@"error", .object_integrity, .{
                .code = "object_schema_invalid",
                .message = "Blame object has an invalid type tag.",
                .path = object_path,
                .hash = try aa.dupe(u8, object_hash),
            });
            return .{
                .kind = .invalid,
                .cache_kind = "blame",
                .path = object_path,
                .raw_size = raw.len,
                .declared_type = "blame",
            };
        }

        var refs: std.ArrayList([hash_mod.hex_len]u8) = .empty;
        for (parsed.value.lines) |line| {
            try refs.append(aa, try parseHexHash(line.step));
        }

        return .{
            .kind = .blame,
            .cache_kind = "blame",
            .path = object_path,
            .raw_size = raw.len,
            .blame_step_refs = try refs.toOwnedSlice(aa),
        };
    }

    if (try parseUnknownJsonType(aa, raw)) |unknown_type| {
        return .{
            .kind = .unknown_json,
            .cache_kind = "blob",
            .path = object_path,
            .raw_size = raw.len,
            .declared_type = unknown_type,
        };
    }

    return .{
        .kind = .blob,
        .cache_kind = "blob",
        .path = object_path,
        .raw_size = raw.len,
    };
}

fn validateReachability(
    aa: std.mem.Allocator,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var iter = objects.iterator();
    while (iter.next()) |entry| {
        const object_hash = entry.key_ptr.*;
        const record = entry.value_ptr;
        switch (record.kind) {
            .tree => {
                for (record.tree_blob_refs) |blob_hash| {
                    if (objects.getPtr(blob_hash)) |target| {
                        target.referenced = true;
                        if (target.kind != .blob) {
                            try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                                .code = "tree_blob_not_blob",
                                .message = "Tree entry points at a non-blob object.",
                                .path = record.path,
                                .hash = try aa.dupe(u8, &blob_hash),
                            });
                        }
                    } else {
                        try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                            .code = "tree_blob_missing",
                            .message = "Tree entry points at a missing blob object.",
                            .path = record.path,
                            .hash = try aa.dupe(u8, &blob_hash),
                        });
                    }
                }
            },
            .step => {
                const step = record.step.?;
                if (step.parent) |parent_hash| {
                    if (objects.getPtr(parent_hash)) |target| {
                        target.referenced = true;
                        if (target.kind != .step) {
                            try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                                .code = "step_parent_not_step",
                                .message = "Step parent points at a non-step object.",
                                .path = record.path,
                                .hash = try aa.dupe(u8, &parent_hash),
                            });
                        }
                    } else {
                        try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                            .code = "step_parent_missing",
                            .message = "Step parent points at a missing object.",
                            .path = record.path,
                            .hash = try aa.dupe(u8, &parent_hash),
                        });
                    }
                }

                if (objects.getPtr(step.tree)) |target| {
                    target.referenced = true;
                    if (target.kind != .tree) {
                        try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                            .code = "step_tree_not_tree",
                            .message = "Step snapshot points at a non-tree object.",
                            .path = record.path,
                            .hash = try aa.dupe(u8, &step.tree),
                        });
                    }
                } else {
                    try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                        .code = "step_tree_missing",
                        .message = "Step snapshot points at a missing tree object.",
                        .path = record.path,
                        .hash = try aa.dupe(u8, &step.tree),
                    });
                }
            },
            .blame => {
                for (record.blame_step_refs) |step_hash| {
                    if (objects.getPtr(step_hash)) |target| {
                        target.referenced = true;
                        if (target.kind != .step) {
                            try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                                .code = "blame_step_not_step",
                                .message = "Blame map points at a non-step object.",
                                .path = record.path,
                                .hash = try aa.dupe(u8, &step_hash),
                            });
                        }
                    } else {
                        try appendFinding(aa, findings, stats, categories, .@"error", .reachability, .{
                            .code = "blame_step_missing",
                            .message = "Blame map points at a missing step object.",
                            .path = record.path,
                            .hash = try aa.dupe(u8, &step_hash),
                        });
                    }
                }
            },
            else => {},
        }

        if (record.kind == .step) {
            if (objects.getPtr(object_hash)) |target| target.referenced = target.referenced;
        }
    }
}

fn scanRefs(
    io: std.Io,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    store_root: std.Io.Dir,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    sessions: *std.StringHashMap(SessionSummary),
    reachable_steps: *std.AutoHashMap([hash_mod.hex_len]u8, StepInfo),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var refs_dir = store_root.openDir(io, "refs/sessions", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer refs_dir.close(io);

    var walker = try refs_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".lock")) continue;
        stats.ref_files += 1;

        const first_sep = std.mem.indexOfScalar(u8, entry.path, '/') orelse {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "ref_path_invalid",
                .message = "Session ref path does not use refs/sessions/<origin-hex>/<session-hex> layout.",
                .path = try std.fmt.allocPrint(aa, ".agit/refs/sessions/{s}", .{entry.path}),
            });
            continue;
        };
        if (std.mem.indexOfScalarPos(u8, entry.path, first_sep + 1, '/') != null) {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "ref_path_invalid",
                .message = "Session ref path has unexpected nested segments.",
                .path = try std.fmt.allocPrint(aa, ".agit/refs/sessions/{s}", .{entry.path}),
            });
            continue;
        }

        const origin = ref_mod.decodePathComponentAlloc(aa, entry.path[0..first_sep]) catch {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "ref_path_invalid",
                .message = "Session ref origin path component is not valid hex.",
                .path = try std.fmt.allocPrint(aa, ".agit/refs/sessions/{s}", .{entry.path}),
            });
            continue;
        };
        const session_id = ref_mod.decodePathComponentAlloc(aa, entry.path[first_sep + 1 ..]) catch {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "ref_path_invalid",
                .message = "Session ref id path component is not valid hex.",
                .path = try std.fmt.allocPrint(aa, ".agit/refs/sessions/{s}", .{entry.path}),
            });
            continue;
        };

        const ref_path = try std.fmt.allocPrint(aa, ".agit/refs/sessions/{s}", .{entry.path});
        const data = refs_dir.readFileAlloc(io, entry.path, gpa, .unlimited) catch |err| {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "ref_unreadable",
                .message = "Session ref could not be read.",
                .hint = @errorName(err),
                .path = ref_path,
            });
            continue;
        };
        defer gpa.free(data);

        const head_hash = parseRefHashToken(data) catch {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "ref_invalid_hash",
                .message = "Session ref must contain exactly one 64-character hash.",
                .path = ref_path,
            });
            continue;
        };

        if (objects.getPtr(head_hash)) |record| {
            record.referenced = true;
            if (record.kind != .step or record.step == null) {
                try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                    .code = "ref_not_step",
                    .message = "Session ref points at a non-step object.",
                    .path = ref_path,
                    .hash = try aa.dupe(u8, &head_hash),
                });
                continue;
            }

            const step = record.step.?;
            if (!std.mem.eql(u8, step.origin, origin) or !std.mem.eql(u8, step.session_id, session_id)) {
                try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                    .code = "ref_session_mismatch",
                    .message = "Session ref points at a step from a different origin/session.",
                    .path = ref_path,
                    .hash = try aa.dupe(u8, &head_hash),
                });
                continue;
            }

            const key = try sessionKey(aa, origin, session_id);
            try sessions.put(key, .{
                .origin = origin,
                .session_id = session_id,
                .head_hash = head_hash,
            });
            stats.reachable_sessions += 1;

            try collectReachableChain(aa, objects, reachable_steps, findings, stats, categories, ref_path, head_hash);
        } else {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "ref_missing_object",
                .message = "Session ref points at a missing object.",
                .path = ref_path,
                .hash = try aa.dupe(u8, &head_hash),
            });
        }
    }

    stats.reachable_steps = reachable_steps.count();
}

fn collectReachableChain(
    aa: std.mem.Allocator,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    reachable_steps: *std.AutoHashMap([hash_mod.hex_len]u8, StepInfo),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
    ref_path: []const u8,
    head_hash: [hash_mod.hex_len]u8,
) !void {
    var chain_seen = std.AutoHashMap([hash_mod.hex_len]u8, void).init(aa);
    var cursor: ?[hash_mod.hex_len]u8 = head_hash;
    while (cursor) |current| {
        if (chain_seen.contains(current)) {
            try appendFinding(aa, findings, stats, categories, .@"error", .refs, .{
                .code = "step_chain_cycle",
                .message = "Step parent chain contains a cycle.",
                .path = ref_path,
                .hash = try aa.dupe(u8, &current),
            });
            break;
        }
        try chain_seen.put(current, {});

        const record = objects.getPtr(current) orelse break;
        record.referenced = true;
        if (record.kind != .step or record.step == null) break;

        if (!reachable_steps.contains(current)) {
            try reachable_steps.put(current, record.step.?);
        }

        cursor = record.step.?.parent;
    }
}

fn warnOnUnknownLooseObjects(
    aa: std.mem.Allocator,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var iter = objects.iterator();
    while (iter.next()) |entry| {
        const record = entry.value_ptr.*;
        if (record.kind != .unknown_json or record.referenced) continue;

        try appendFinding(aa, findings, stats, categories, .warn, .object_integrity, .{
            .code = "object_unknown_type",
            .message = try std.fmt.allocPrint(aa, "Loose JSON object declares unsupported type `{s}`.", .{record.declared_type.?}),
            .path = record.path,
            .hash = try aa.dupe(u8, &entry.key_ptr.*),
        });
    }
}

fn inspectIndex(
    io: std.Io,
    aa: std.mem.Allocator,
    store_abs_path: []const u8,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    sessions: *std.StringHashMap(SessionSummary),
    reachable_steps: *std.AutoHashMap([hash_mod.hex_len]u8, StepInfo),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    const index_path = try std.fmt.allocPrint(aa, "{s}/index.db", .{store_abs_path});
    const probe = std.Io.Dir.cwd().openFile(io, index_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try appendFinding(aa, findings, stats, categories, .warn, .index, .{
                .code = "index_unreadable",
                .message = "index.db could not be opened for inspection.",
                .hint = @errorName(err),
                .path = ".agit/index.db",
            });
            return;
        },
    };
    defer if (probe) |file| file.close(io);
    if (probe == null) {
        const severity: Severity = if (objects.count() == 0 and sessions.count() == 0) .info else .warn;
        try appendFinding(aa, findings, stats, categories, severity, .index, .{
            .code = "index_missing",
            .message = "index.db is missing; the store can be reindexed from object/ref truth.",
            .hint = "Run `agit fsck --reindex` or `agit reindex` to rebuild the query index.",
            .path = ".agit/index.db",
        });
        return;
    }

    var index = index_mod.Index.openReadOnly(aa, index_path) catch |err| {
        try appendFinding(aa, findings, stats, categories, .warn, .index, .{
            .code = "index_unreadable",
            .message = "index.db could not be opened read-only.",
            .hint = @errorName(err),
            .path = ".agit/index.db",
        });
        return;
    };
    defer index.close();

    const has_schema_migrations = try hasTable(index.db, "schema_migrations");
    const has_sessions = try hasTable(index.db, "sessions");
    const has_steps = try hasTable(index.db, "steps");
    const has_messages = try hasTable(index.db, "messages");
    const has_tool_calls = try hasTable(index.db, "tool_calls");
    const has_objects = try hasTable(index.db, "objects");
    if (!has_schema_migrations or !has_sessions or !has_steps or !has_messages or !has_tool_calls or !has_objects) {
        try appendFinding(aa, findings, stats, categories, .warn, .index, .{
            .code = "index_schema_drift",
            .message = "index.db is missing one or more required tables for the current schema.",
            .hint = "Run `agit fsck --reindex` or `agit reindex` to rebuild the query index.",
            .path = ".agit/index.db",
        });
        return;
    }

    const schema_version = try readSchemaVersion(index.db);
    if (schema_version != index_mod.Index.current_schema_version) {
        try appendFinding(aa, findings, stats, categories, .warn, .index, .{
            .code = "index_schema_drift",
            .message = try std.fmt.allocPrint(aa, "index.db schema version is {d}, expected {d}.", .{
                schema_version,
                index_mod.Index.current_schema_version,
            }),
            .hint = "Run `agit fsck --reindex` or `agit reindex` to rebuild the query index.",
            .path = ".agit/index.db",
        });
    }

    try inspectSessionRows(aa, index.db, sessions, findings, stats, categories);
    try inspectStepRows(aa, index.db, reachable_steps, findings, stats, categories);
    try inspectCountRows(aa, index.db, reachable_steps, findings, stats, categories, "messages", "index_messages_drift", "message");
    try inspectCountRows(aa, index.db, reachable_steps, findings, stats, categories, "tool_calls", "index_tool_calls_drift", "tool call");
    try inspectObjectRows(aa, index.db, objects, findings, stats, categories);
}

fn inspectSessionRows(
    aa: std.mem.Allocator,
    db: zqlite.Conn,
    sessions: *std.StringHashMap(SessionSummary),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var seen = std.StringHashMap(void).init(aa);
    var rows = try db.rows("select origin, session_id, head_hash from sessions", .{});
    defer rows.deinit();

    var missing: usize = 0;
    var extra: usize = 0;
    var mismatched: usize = 0;
    while (rows.next()) |row| {
        const origin = row.get([]const u8, 0);
        const session_id = row.get([]const u8, 1);
        const head_hash = row.get(?[]const u8, 2);
        const key = try sessionKey(aa, origin, session_id);
        try seen.put(key, {});
        if (sessions.get(key)) |expected| {
            if (head_hash == null or !std.mem.eql(u8, head_hash.?, &expected.head_hash)) mismatched += 1;
        } else {
            extra += 1;
        }
    }
    if (rows.err) |err| return err;

    var iter = sessions.iterator();
    while (iter.next()) |entry| {
        if (!seen.contains(entry.key_ptr.*)) missing += 1;
    }

    if (missing > 0 or extra > 0 or mismatched > 0) {
        try appendFinding(aa, findings, stats, categories, .warn, .index, .{
            .code = "index_sessions_drift",
            .message = try std.fmt.allocPrint(aa, "Session index drift detected: missing={d} extra={d} mismatched_heads={d}.", .{
                missing,
                extra,
                mismatched,
            }),
            .hint = "Run `agit fsck --reindex` or `agit reindex` to rebuild the query index.",
            .path = ".agit/index.db",
        });
    }
}

fn inspectStepRows(
    aa: std.mem.Allocator,
    db: zqlite.Conn,
    reachable_steps: *std.AutoHashMap([hash_mod.hex_len]u8, StepInfo),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var seen = std.AutoHashMap([hash_mod.hex_len]u8, void).init(aa);
    var rows = try db.rows(
        "select hash, session_origin, session_id, turn_id, parent_hash, tree_hash, timestamp from steps",
        .{},
    );
    defer rows.deinit();

    var extra: usize = 0;
    var mismatched: usize = 0;
    while (rows.next()) |row| {
        const hash_hex = row.get([]const u8, 0);
        const key = parseHexHash(hash_hex) catch {
            extra += 1;
            continue;
        };
        try seen.put(key, {});
        if (reachable_steps.get(key)) |expected| {
            const parent_hash = if (row.get(?[]const u8, 4)) |parent| try parseHexHash(parent) else null;
            const tree_hash = try parseHexHash(row.get([]const u8, 5));
            if (!std.mem.eql(u8, row.get([]const u8, 1), expected.origin) or
                !std.mem.eql(u8, row.get([]const u8, 2), expected.session_id) or
                !std.mem.eql(u8, row.get([]const u8, 3), expected.turn_id) or
                !hashOptEq(parent_hash, expected.parent) or
                !std.mem.eql(u8, &tree_hash, &expected.tree) or
                row.get(i64, 6) != expected.timestamp)
            {
                mismatched += 1;
            }
        } else {
            extra += 1;
        }
    }
    if (rows.err) |err| return err;

    var missing: usize = 0;
    var iter = reachable_steps.iterator();
    while (iter.next()) |entry| {
        if (!seen.contains(entry.key_ptr.*)) missing += 1;
    }

    if (missing > 0 or extra > 0 or mismatched > 0) {
        try appendFinding(aa, findings, stats, categories, .warn, .index, .{
            .code = "index_steps_drift",
            .message = try std.fmt.allocPrint(aa, "Step index drift detected: missing={d} extra={d} mismatched={d}.", .{
                missing,
                extra,
                mismatched,
            }),
            .hint = "Run `agit fsck --reindex` or `agit reindex` to rebuild the query index.",
            .path = ".agit/index.db",
        });
    }
}

fn inspectCountRows(
    aa: std.mem.Allocator,
    db: zqlite.Conn,
    reachable_steps: *std.AutoHashMap([hash_mod.hex_len]u8, StepInfo),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
    comptime table_name: []const u8,
    comptime code: []const u8,
    comptime label: []const u8,
) !void {
    const sql = "select step_hash, count(*) from " ++ table_name ++ " group by step_hash";
    var seen = std.AutoHashMap([hash_mod.hex_len]u8, usize).init(aa);
    var rows = try db.rows(sql, .{});
    defer rows.deinit();

    var extra: usize = 0;
    var mismatched: usize = 0;
    while (rows.next()) |row| {
        const hash_hex = row.get([]const u8, 0);
        const key = parseHexHash(hash_hex) catch {
            extra += 1;
            continue;
        };
        const count: usize = @intCast(row.get(i64, 1));
        try seen.put(key, count);
        if (reachable_steps.get(key)) |expected| {
            const wanted = if (std.mem.eql(u8, label, "message")) expected.message_count else expected.tool_call_count;
            if (count != wanted) mismatched += 1;
        } else {
            extra += 1;
        }
    }
    if (rows.err) |err| return err;

    var missing: usize = 0;
    var iter = reachable_steps.iterator();
    while (iter.next()) |entry| {
        const wanted = if (std.mem.eql(u8, label, "message")) entry.value_ptr.message_count else entry.value_ptr.tool_call_count;
        if (wanted == 0) continue;
        if (!seen.contains(entry.key_ptr.*)) missing += 1;
    }

    if (missing > 0 or extra > 0 or mismatched > 0) {
        try appendFinding(aa, findings, stats, categories, .warn, .index, .{
            .code = code,
            .message = try std.fmt.allocPrint(aa, "{s} index drift detected: missing={d} extra={d} mismatched={d}.", .{
                std.ascii.allocLowerString(aa, label) catch label,
                missing,
                extra,
                mismatched,
            }),
            .hint = "Run `agit fsck --reindex` or `agit reindex` to rebuild the query index.",
            .path = ".agit/index.db",
        });
    }
}

fn inspectObjectRows(
    aa: std.mem.Allocator,
    db: zqlite.Conn,
    objects: *std.AutoHashMap([hash_mod.hex_len]u8, ObjectRecord),
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var seen = std.AutoHashMap([hash_mod.hex_len]u8, void).init(aa);
    var rows = try db.rows("select hash, kind, size from objects", .{});
    defer rows.deinit();

    var extra: usize = 0;
    var mismatched: usize = 0;
    while (rows.next()) |row| {
        const hash_hex = row.get([]const u8, 0);
        const key = parseHexHash(hash_hex) catch {
            extra += 1;
            continue;
        };
        try seen.put(key, {});
        if (objects.get(key)) |expected| {
            const size: usize = @intCast(row.get(i64, 2));
            if (!std.mem.eql(u8, row.get([]const u8, 1), expected.cache_kind) or size != expected.raw_size) mismatched += 1;
        } else {
            extra += 1;
        }
    }
    if (rows.err) |err| return err;

    var missing: usize = 0;
    var iter = objects.iterator();
    while (iter.next()) |entry| {
        if (!seen.contains(entry.key_ptr.*)) missing += 1;
    }

    if (missing > 0 or extra > 0 or mismatched > 0) {
        try appendFinding(aa, findings, stats, categories, .warn, .index, .{
            .code = "index_objects_drift",
            .message = try std.fmt.allocPrint(aa, "Object cache drift detected: missing={d} extra={d} mismatched={d}.", .{
                missing,
                extra,
                mismatched,
            }),
            .hint = "Run `agit fsck --reindex` or `agit reindex` to rebuild the query index.",
            .path = ".agit/index.db",
        });
    }
}

fn inspectMutableArea(
    io: std.Io,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    store_root: std.Io.Dir,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    try inspectStaging(io, gpa, aa, store_root, findings, stats, categories);
    try inspectLocks(io, gpa, aa, store_root, findings, stats, categories);
}

fn inspectStaging(
    io: std.Io,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    store_root: std.Io.Dir,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var tmp_dir = store_root.openDir(io, "tmp", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer tmp_dir.close(io);

    var walker = try tmp_dir.walk(gpa);
    defer walker.deinit();

    var corrupt_json: usize = 0;
    var unreadable: usize = 0;
    var quarantined: usize = 0;
    var pending_json: usize = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".json.lock")) continue;
        if (std.mem.endsWith(u8, entry.path, ".json.corrupt") or std.mem.endsWith(u8, entry.path, ".corrupt")) {
            quarantined += 1;
            continue;
        }
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

        const raw = tmp_dir.readFileAlloc(io, entry.path, gpa, .unlimited) catch {
            unreadable += 1;
            continue;
        };
        defer gpa.free(raw);

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{ .allocate = .alloc_always }) catch {
            corrupt_json += 1;
            continue;
        };
        defer parsed.deinit();
        pending_json += 1;
    }

    if (corrupt_json > 0 or unreadable > 0) {
        try appendFinding(aa, findings, stats, categories, .warn, .mutable, .{
            .code = "staging_corrupt",
            .message = try std.fmt.allocPrint(aa, "Mutable staging area contains {d} corrupt JSON file(s) and {d} unreadable file(s).", .{
                corrupt_json,
                unreadable,
            }),
            .hint = "Inspect .agit/tmp and .agit/log/hook-error.log.",
            .path = ".agit/tmp",
        });
    } else if (quarantined > 0) {
        try appendFinding(aa, findings, stats, categories, .warn, .mutable, .{
            .code = "staging_quarantined",
            .message = try std.fmt.allocPrint(aa, "Mutable staging area contains {d} quarantined corrupt file(s).", .{quarantined}),
            .path = ".agit/tmp",
        });
    } else if (pending_json > 0) {
        try appendFinding(aa, findings, stats, categories, .info, .mutable, .{
            .code = "staging_pending",
            .message = try std.fmt.allocPrint(aa, "Mutable staging area contains {d} pending capture file(s).", .{pending_json}),
            .path = ".agit/tmp",
        });
    }
}

fn inspectLocks(
    io: std.Io,
    gpa: std.mem.Allocator,
    aa: std.mem.Allocator,
    store_root: std.Io.Dir,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) !void {
    var root_iter_dir = try store_root.openDir(io, ".", .{ .iterate = true });
    defer root_iter_dir.close(io);

    var walker = try root_iter_dir.walk(gpa);
    defer walker.deinit();

    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".lock")) continue;

        const path = try std.fmt.allocPrint(aa, ".agit/{s}", .{entry.path});
        const data = store_root.readFileAlloc(io, entry.path, gpa, .unlimited) catch {
            try appendFinding(aa, findings, stats, categories, .warn, .mutable, .{
                .code = "lock_unreadable",
                .message = "Lock file is unreadable.",
                .path = path,
            });
            continue;
        };
        defer gpa.free(data);

        const text = std.mem.trim(u8, data, "\n\r ");
        var parsed = std.json.parseFromSlice(file_lock_mod.LockRecord, gpa, text, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try appendFinding(aa, findings, stats, categories, .warn, .mutable, .{
                .code = "lock_malformed",
                .message = "Lock file contents are malformed JSON.",
                .path = path,
            });
            continue;
        };
        defer parsed.deinit();

        const age_ms: i64 = @max(0, now_ms - parsed.value.started_at);
        if (age_ms > expected_lock_stale_after_ms or parsed.value.pid <= 0) {
            try appendFinding(aa, findings, stats, categories, .warn, .mutable, .{
                .code = "lock_stale",
                .message = try std.fmt.allocPrint(aa, "Lock file looks stale (age_ms={d}, pid={d}).", .{
                    age_ms,
                    parsed.value.pid,
                }),
                .path = path,
            });
        } else {
            try appendFinding(aa, findings, stats, categories, .info, .mutable, .{
                .code = "lock_present",
                .message = try std.fmt.allocPrint(aa, "Active lock file present (age_ms={d}, pid={d}).", .{
                    age_ms,
                    parsed.value.pid,
                }),
                .path = path,
            });
        }
    }
}

fn appendOkFindings(
    aa: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
) void {
    if (!categories.object_integrity_issue) {
        appendFindingNoFail(aa, findings, stats, .ok, .{
            .code = "object_integrity_ok",
            .message = tryAllocPrint(aa, "Validated {d} stored object(s).", .{stats.object_files}),
        });
    }
    if (!categories.reachability_issue) {
        appendFindingNoFail(aa, findings, stats, .ok, .{
            .code = "reachability_ok",
            .message = "No broken object links detected.",
        });
    }
    if (!categories.ref_issue) {
        appendFindingNoFail(aa, findings, stats, .ok, .{
            .code = "refs_ok",
            .message = tryAllocPrint(aa, "Validated {d} session ref file(s).", .{stats.ref_files}),
        });
    }
    if (!categories.index_issue) {
        appendFindingNoFail(aa, findings, stats, .ok, .{
            .code = "index_ok",
            .message = "index.db matches reachable object/ref state.",
            .path = ".agit/index.db",
        });
    }
    if (!categories.mutable_issue) {
        appendFindingNoFail(aa, findings, stats, .ok, .{
            .code = "mutable_area_ok",
            .message = "Mutable staging and lock areas are clean.",
            .path = ".agit/tmp",
        });
    }
}

const Category = enum {
    object_integrity,
    reachability,
    refs,
    index,
    mutable,
};

fn appendFinding(
    aa: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    categories: *CategoryState,
    severity: Severity,
    category: Category,
    finding: anytype,
) !void {
    switch (category) {
        .object_integrity => {
            if (severity != .ok) categories.object_integrity_issue = true;
        },
        .reachability => {
            if (severity != .ok) categories.reachability_issue = true;
        },
        .refs => {
            if (severity != .ok) categories.ref_issue = true;
        },
        .index => {
            if (severity != .ok) categories.index_issue = true;
        },
        .mutable => {
            if (severity != .ok) categories.mutable_issue = true;
        },
    }
    switch (severity) {
        .warn => stats.warnings += 1,
        .@"error" => stats.errors += 1,
        else => {},
    }
    try findings.append(aa, .{
        .code = finding.code,
        .severity = severity,
        .message = finding.message,
        .hint = fieldOrNull(finding, "hint"),
        .path = fieldOrNull(finding, "path"),
        .hash = fieldOrNull(finding, "hash"),
    });
}

fn appendFindingNoFail(
    aa: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    severity: Severity,
    finding: anytype,
) void {
    findings.append(aa, .{
        .code = finding.code,
        .severity = severity,
        .message = finding.message,
        .hint = fieldOrNull(finding, "hint"),
        .path = fieldOrNull(finding, "path"),
        .hash = fieldOrNull(finding, "hash"),
    }) catch return;
    switch (severity) {
        .warn => stats.warnings += 1,
        .@"error" => stats.errors += 1,
        else => {},
    }
}

fn fieldOrNull(finding: anytype, comptime field_name: []const u8) ?[]const u8 {
    if (@hasField(@TypeOf(finding), field_name)) {
        return @field(finding, field_name);
    }
    return null;
}

fn tryAllocPrint(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(allocator, fmt, args) catch "";
}

fn parseUnknownJsonType(aa: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, aa, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const type_value = parsed.value.object.get("type") orelse return null;
    if (type_value != .string) return null;
    if (std.mem.eql(u8, type_value.string, "tree") or
        std.mem.eql(u8, type_value.string, "step") or
        std.mem.eql(u8, type_value.string, "blame"))
    {
        return null;
    }
    return try aa.dupe(u8, type_value.string);
}

fn parseHexHash(hex: []const u8) ![hash_mod.hex_len]u8 {
    if (hex.len != hash_mod.hex_len) return error.InvalidHash;
    var buf: [hash_mod.hex_len]u8 = undefined;
    @memcpy(buf[0..], hex[0..hash_mod.hex_len]);
    _ = try hash_mod.Hash.fromHex(&buf);
    return buf;
}

fn parseRefHashToken(content: []const u8) ![hash_mod.hex_len]u8 {
    var tokens = std.mem.tokenizeAny(u8, content, " \t\r\n");
    const first = tokens.next() orelse return error.InvalidHash;
    if (tokens.next() != null) return error.InvalidHash;
    return parseHexHash(first);
}

fn sessionKey(aa: std.mem.Allocator, origin: []const u8, session_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(aa, "{s}\x00{s}", .{ origin, session_id });
}

fn hashOptEq(a: ?[hash_mod.hex_len]u8, b: ?[hash_mod.hex_len]u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, &a.?, &b.?);
}

fn hasTable(db: zqlite.Conn, table_name: []const u8) !bool {
    const row = try db.row(
        "select 1 from sqlite_master where type='table' and name=? limit 1",
        .{table_name},
    );
    if (row) |r| {
        defer r.deinit();
        return true;
    }
    return false;
}

fn readSchemaVersion(db: zqlite.Conn) !i64 {
    const row = try db.row(
        "select coalesce(max(version), 0) from schema_migrations",
        .{},
    ) orelse return 0;
    defer row.deinit();
    return row.get(i64, 0);
}

test "scan reports object hash mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".agit/objects");
    try tmp.dir.createDirPath(io, ".agit/refs/sessions");
    try tmp.dir.createDirPath(io, ".agit/tmp");

    const hash = try object_mod.write(io, try tmp.dir.openDir(io, ".agit", .{}), "hello");
    const hex = hash.toHex();
    const object_path = try std.fmt.allocPrint(std.testing.allocator, ".agit/objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    defer std.testing.allocator.free(object_path);

    var corrupt = try tmp.dir.createFile(io, object_path, .{ .truncate = true });
    defer corrupt.close(io);
    try corrupt.writeStreamingAll(io, "goodbye");

    var agit = try tmp.dir.openDir(io, ".agit", .{});
    defer agit.close(io);
    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try agit.realPath(io, &root_path_buf);
    var report = try scan(io, std.testing.allocator, agit, root_path_buf[0..n]);
    defer report.deinit();

    try std.testing.expect(report.hasErrors());
    try std.testing.expect(hasFinding(report.findings, "object_hash_mismatch"));
}

test "scan reports missing tree blob" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".agit/objects");
    try tmp.dir.createDirPath(io, ".agit/refs/sessions");
    try tmp.dir.createDirPath(io, ".agit/tmp");

    var agit = try tmp.dir.openDir(io, ".agit", .{});
    defer agit.close(io);

    const tree = object_mod.Tree{
        .entries = &.{
            .{
                .path = "src/main.zig",
                .blob = "a" ** 64,
                .mode = "file",
                .size = 1,
            },
        },
    };
    _ = try object_mod.writeTree(io, agit, std.testing.allocator, tree);

    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try agit.realPath(io, &root_path_buf);
    var report = try scan(io, std.testing.allocator, agit, root_path_buf[0..n]);
    defer report.deinit();

    try std.testing.expect(report.hasErrors());
    try std.testing.expect(hasFinding(report.findings, "tree_blob_missing"));
}

test "scan reports missing step parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".agit/objects");
    try tmp.dir.createDirPath(io, ".agit/refs/sessions");
    try tmp.dir.createDirPath(io, ".agit/tmp");

    var agit = try tmp.dir.openDir(io, ".agit", .{});
    defer agit.close(io);

    const empty_tree = object_mod.Tree{ .entries = &.{} };
    const tree_hash = try object_mod.writeTree(io, agit, std.testing.allocator, empty_tree);
    const tree_hex = tree_hash.toHex();

    const step = object_mod.Step{
        .parent = "f" ** 64,
        .tree = &tree_hex,
        .session_id = "session-1",
        .origin = "claude",
        .turn_id = "turn-1",
        .causes = &.{},
        .timestamp = 1,
    };
    _ = try object_mod.writeStep(io, agit, std.testing.allocator, step);

    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try agit.realPath(io, &root_path_buf);
    var report = try scan(io, std.testing.allocator, agit, root_path_buf[0..n]);
    defer report.deinit();

    try std.testing.expect(report.hasErrors());
    try std.testing.expect(hasFinding(report.findings, "step_parent_missing"));
}

test "scan reports corrupt ref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, ".agit/objects");
    try tmp.dir.createDirPath(io, ".agit/refs/sessions");
    try tmp.dir.createDirPath(io, ".agit/tmp");

    const origin_hex = std.fmt.bytesToHex("claude", .lower);
    const session_hex = std.fmt.bytesToHex("session-1", .lower);
    const ref_path = try std.fmt.allocPrint(std.testing.allocator, ".agit/refs/sessions/{s}/{s}", .{ &origin_hex, &session_hex });
    defer std.testing.allocator.free(ref_path);
    const parent_end = std.mem.lastIndexOfScalar(u8, ref_path, '/') orelse unreachable;
    try tmp.dir.createDirPath(io, ref_path[0..parent_end]);
    var ref_file = try tmp.dir.createFile(io, ref_path, .{ .truncate = true });
    defer ref_file.close(io);
    try ref_file.writeStreamingAll(io, "not-a-hash\n");

    var agit = try tmp.dir.openDir(io, ".agit", .{});
    defer agit.close(io);
    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try agit.realPath(io, &root_path_buf);
    var report = try scan(io, std.testing.allocator, agit, root_path_buf[0..n]);
    defer report.deinit();

    try std.testing.expect(report.hasErrors());
    try std.testing.expect(hasFinding(report.findings, "ref_invalid_hash"));
}

test "scan reports index drift as warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var store = try @import("store.zig").Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const tree_hash = try store.writeTree(io, gpa, .{ .entries = &.{} });
    const tree_hex = tree_hash.toHex();
    const step = object_mod.Step{
        .parent = null,
        .tree = &tree_hex,
        .session_id = "session-1",
        .origin = "claude",
        .turn_id = "turn-1",
        .causes = &.{},
        .timestamp = 1,
    };
    const step_write = try object_mod.writeStepDetailed(io, store.root, gpa, step);
    const step_hex = step_write.hash.toHex();
    try store.index.insertObject(&step_hex, "step", step_write.size);
    try ref_mod.writeSessionRef(io, store.root, gpa, "claude", "session-1", step_write.hash);
    try store.index.upsertSession("claude", "session-1", &step_hex);
    try store.index.insertStep(&step_hex, "claude", "session-1", "turn-1", null, &tree_hex, 1, null, null, null, null);
    try store.index.db.exec("delete from steps where hash=?", .{&step_hex});

    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try store.root.realPath(io, &root_path_buf);
    var report = try scan(io, gpa, store.root, root_path_buf[0..n]);
    defer report.deinit();

    try std.testing.expect(!report.hasErrors());
    try std.testing.expect(report.hasWarnings());
    try std.testing.expect(hasFinding(report.findings, "index_steps_drift"));
}

fn hasFinding(findings: []const Finding, code: []const u8) bool {
    for (findings) |finding| {
        if (std.mem.eql(u8, finding.code, code)) return true;
    }
    return false;
}

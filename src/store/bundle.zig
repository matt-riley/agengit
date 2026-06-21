const std = @import("std");

const blame_mod = @import("blame.zig");
const fs_mod = @import("../util/fs.zig");
const hash_mod = @import("hash.zig");
const object_mod = @import("object.zig");
const ref_mod = @import("ref.zig");
const store_mod = @import("store.zig");

pub const bundle_format = "agit-bundle-v1";
const privacy_report_path = "privacy-report.json";

pub const SessionFilter = struct {
    origin: []const u8,
    session_id: []const u8,
};

pub const ExportFilters = struct {
    origin: ?[]const u8 = null,
    session: ?SessionFilter = null,
    session_text: ?[]const u8 = null,
    since_text: ?[]const u8 = null,
    until_text: ?[]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
};

pub const ExportOptions = struct {
    path: []const u8,
    producer_version: []const u8,
    repository_hint: ?[]const u8 = null,
    filters: ExportFilters = .{},
    privacy_findings: usize = 0,
    privacy_report_json: ?[]const u8 = null,
};

pub const ImportOptions = struct {
    path: []const u8,
    replace_refs: []const SessionFilter = &.{},
};

pub const ExportResult = struct {
    bundle_id: [hash_mod.hex_len]u8,
    exported_objects: usize,
    exported_refs: usize,
};

pub const ImportResult = struct {
    bundle_id: [hash_mod.hex_len]u8,
    imported_objects: usize = 0,
    skipped_objects: usize = 0,
    cloned_steps: usize = 0,
    created_refs: usize = 0,
    replaced_refs: usize = 0,
    namespaced_refs: usize = 0,
    unchanged_refs: usize = 0,
};

pub const ManifestFilters = struct {
    origin: ?[]const u8 = null,
    session: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
};

pub const ObjectSchemaVersions = struct {
    tree: u8 = 1,
    step: u8 = 1,
    blame: u8 = 1,
};

pub const ManifestRef = struct {
    path: []const u8,
    origin: []const u8,
    session_id: []const u8,
    head_hash: []const u8,
};

pub const ManifestObject = struct {
    hash: []const u8,
    kind: []const u8,
    size: usize,
    path: []const u8,
};

pub const ManifestPrivacy = struct {
    clean: bool,
    findings: usize,
    report_path: ?[]const u8 = null,
};

pub const EncryptionMetadata = struct {};

pub const Manifest = struct {
    bundle_format: []const u8,
    bundle_id: []const u8,
    producer_version: []const u8,
    created_at_ms: i64,
    repository_hint: ?[]const u8 = null,
    filters: ManifestFilters,
    object_schema_versions: ObjectSchemaVersions = .{},
    refs: []const ManifestRef,
    objects: []const ManifestObject,
    privacy: ManifestPrivacy,
    encryption: ?EncryptionMetadata = null,
};

const SelectedRef = struct {
    origin: []u8,
    session_id: []u8,
    path: []u8,
    head_hash: []u8,

    fn deinit(self: SelectedRef, gpa: std.mem.Allocator) void {
        gpa.free(self.origin);
        gpa.free(self.session_id);
        gpa.free(self.path);
        gpa.free(self.head_hash);
    }
};

const RefIdent = struct {
    origin: []u8,
    session_id: []u8,

    fn deinit(self: RefIdent, gpa: std.mem.Allocator) void {
        gpa.free(self.origin);
        gpa.free(self.session_id);
    }
};

const ObjectLink = struct {
    hash: []u8,
    kind: []const u8,
    size: usize,
    path: []u8,

    fn deinit(self: ObjectLink, gpa: std.mem.Allocator) void {
        gpa.free(self.hash);
        gpa.free(self.path);
    }
};

pub fn selectRefs(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    filters: ExportFilters,
) ![]const ManifestRef {
    const selected = try collectSelectedRefs(io, gpa, store, filters);
    defer freeSelectedRefs(gpa, selected);

    const refs = try gpa.alloc(ManifestRef, selected.len);
    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |ref| {
            gpa.free(@constCast(ref.path));
            gpa.free(@constCast(ref.origin));
            gpa.free(@constCast(ref.session_id));
            gpa.free(@constCast(ref.head_hash));
        }
        gpa.free(refs);
    }

    for (selected, 0..) |ref, i| {
        refs[i] = .{
            .path = try gpa.dupe(u8, ref.path),
            .origin = try gpa.dupe(u8, ref.origin),
            .session_id = try gpa.dupe(u8, ref.session_id),
            .head_hash = try gpa.dupe(u8, ref.head_hash),
        };
        initialized = i + 1;
    }
    return refs;
}

pub fn freeManifestRefs(gpa: std.mem.Allocator, refs: []const ManifestRef) void {
    for (refs) |ref| {
        gpa.free(@constCast(ref.path));
        gpa.free(@constCast(ref.origin));
        gpa.free(@constCast(ref.session_id));
        gpa.free(@constCast(ref.head_hash));
    }
    gpa.free(refs);
}

pub fn exportBundle(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    options: ExportOptions,
) !ExportResult {
    const selected = try collectSelectedRefs(io, gpa, store, options.filters);
    defer freeSelectedRefs(gpa, selected);
    if (selected.len == 0) return error.NoMatchingSessions;

    const objects = try collectReachableObjects(io, gpa, store, selected);
    defer freeObjectLinks(gpa, objects);

    const created_at_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const bundle_id = try computeBundleId(gpa, selected, created_at_ms);

    var bundle_dir = try ensureBundleDir(io, options.path);
    defer bundle_dir.close(io);

    for (objects) |object_link| {
        const hash = try hash_mod.Hash.fromHex(object_link.hash);
        const raw = try store.readBlob(io, gpa, hash);
        defer gpa.free(raw);
        try writeFileAtomic(io, bundle_dir, object_link.path, raw);
    }

    for (selected) |ref| {
        const hash = try hash_mod.Hash.fromHex(ref.head_hash);
        try ref_mod.writeRefToPath(io, bundle_dir, ref.path, hash);
    }

    const manifest_refs = try buildManifestRefs(gpa, selected);
    defer freeManifestRefs(gpa, manifest_refs);
    const manifest_objects = try buildManifestObjects(gpa, objects);
    defer freeManifestObjects(gpa, manifest_objects);

    const manifest = Manifest{
        .bundle_format = bundle_format,
        .bundle_id = bundle_id[0..],
        .producer_version = options.producer_version,
        .created_at_ms = created_at_ms,
        .repository_hint = options.repository_hint,
        .filters = .{
            .origin = options.filters.origin,
            .session = options.filters.session_text,
            .since = options.filters.since_text,
            .until = options.filters.until_text,
        },
        .refs = manifest_refs,
        .objects = manifest_objects,
        .privacy = .{
            .clean = options.privacy_findings == 0,
            .findings = options.privacy_findings,
            .report_path = if (options.privacy_report_json != null) privacy_report_path else null,
        },
        .encryption = null,
    };

    if (options.privacy_report_json) |report_json| {
        try writeFileAtomic(io, bundle_dir, privacy_report_path, report_json);
    }
    try writeJsonAtomic(io, gpa, bundle_dir, "manifest.json", manifest);

    return .{
        .bundle_id = bundle_id,
        .exported_objects = objects.len,
        .exported_refs = selected.len,
    };
}

pub fn importBundle(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    options: ImportOptions,
) !ImportResult {
    var bundle_dir = try std.Io.Dir.cwd().openDir(io, options.path, .{ .iterate = true });
    defer bundle_dir.close(io);

    const manifest_raw = try bundle_dir.readFileAlloc(io, "manifest.json", gpa, .unlimited);
    defer gpa.free(manifest_raw);

    var parsed = try std.json.parseFromSlice(Manifest, gpa, manifest_raw, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const manifest = parsed.value;

    try validateManifest(gpa, &manifest);
    try validatePrivacyReportPath(gpa, io, bundle_dir, &manifest);
    try validateBundleObjects(io, gpa, bundle_dir, &manifest);

    var object_map = try buildObjectMap(gpa, &manifest);
    defer object_map.deinit();

    var result = ImportResult{
        .bundle_id = blk: {
            var out: [hash_mod.hex_len]u8 = undefined;
            @memcpy(&out, manifest.bundle_id);
            break :blk out;
        },
    };

    for (manifest.objects) |object_entry| {
        const hash = try hash_mod.Hash.fromHex(object_entry.hash);
        const existing = store.readBlob(io, gpa, hash) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => return err,
        };
        if (existing) |raw| {
            gpa.free(raw);
            result.skipped_objects += 1;
            continue;
        }
        const raw = try bundle_dir.readFileAlloc(io, object_entry.path, gpa, .unlimited);
        defer gpa.free(raw);
        const written = try object_mod.writeDetailed(io, store.root, raw);
        const written_hex = written.hash.toHex();
        if (!std.mem.eql(u8, &written_hex, object_entry.hash)) return error.BundleHashMismatch;
        result.imported_objects += 1;
    }

    for (manifest.refs) |ref_entry| {
        const head_hash = try hash_mod.Hash.fromHex(ref_entry.head_hash);
        const current = try store.readRef(io, gpa, ref_entry.origin, ref_entry.session_id);
        if (current == null) {
            try ref_mod.writeSessionRef(io, store.root, gpa, ref_entry.origin, ref_entry.session_id, head_hash);
            result.created_refs += 1;
            continue;
        }
        if (current.?.eql(head_hash)) {
            result.unchanged_refs += 1;
            continue;
        }
        if (shouldReplaceRef(options.replace_refs, ref_entry.origin, ref_entry.session_id)) {
            try ref_mod.writeSessionRef(io, store.root, gpa, ref_entry.origin, ref_entry.session_id, head_hash);
            result.replaced_refs += 1;
            continue;
        }

        const namespaced_session_id = try namespacedSessionIdAlloc(gpa, ref_entry.session_id, manifest.bundle_id);
        defer gpa.free(namespaced_session_id);
        const rewritten_head = try cloneNamespacedSessionChain(io, gpa, store, bundle_dir, &object_map, ref_entry.head_hash, namespaced_session_id, &result);
        const namespaced_current = try store.readRef(io, gpa, ref_entry.origin, namespaced_session_id);
        if (namespaced_current) |hash| {
            if (!hash.eql(rewritten_head)) return error.BundleRefConflict;
            result.unchanged_refs += 1;
            continue;
        }
        try ref_mod.writeSessionRef(io, store.root, gpa, ref_entry.origin, namespaced_session_id, rewritten_head);
        result.namespaced_refs += 1;
    }

    if (result.imported_objects > 0 or result.cloned_steps > 0) {
        try store.index.setObjectsComplete(false);
    }

    return result;
}

fn collectSelectedRefs(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    filters: ExportFilters,
) ![]const SelectedRef {
    const sessions = try listRefSessions(io, gpa, store);
    defer freeRefIdents(gpa, sessions);

    var selected: std.ArrayList(SelectedRef) = .empty;
    errdefer {
        for (selected.items) |*ref| ref.deinit(gpa);
        selected.deinit(gpa);
    }

    for (sessions) |session| {
        if (filters.origin) |origin| {
            if (!std.mem.eql(u8, session.origin, origin)) continue;
        }
        if (filters.session) |wanted| {
            if (!std.mem.eql(u8, session.origin, wanted.origin) or !std.mem.eql(u8, session.session_id, wanted.session_id)) continue;
        }

        const head = try store.readRef(io, gpa, session.origin, session.session_id) orelse continue;
        if (!try sessionMatchesWindow(io, gpa, store, head, filters.since_ms, filters.until_ms_exclusive)) continue;

        const head_hex = head.toHex();
        try selected.append(gpa, .{
            .origin = try gpa.dupe(u8, session.origin),
            .session_id = try gpa.dupe(u8, session.session_id),
            .path = try ref_mod.buildRefPath(gpa, session.origin, session.session_id),
            .head_hash = try gpa.dupe(u8, &head_hex),
        });
    }

    std.mem.sort(SelectedRef, selected.items, {}, lessThanSelectedRef);
    return selected.toOwnedSlice(gpa);
}

fn lessThanSelectedRef(_: void, a: SelectedRef, b: SelectedRef) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn freeSelectedRefs(gpa: std.mem.Allocator, selected: []const SelectedRef) void {
    for (selected) |ref| ref.deinit(gpa);
    gpa.free(selected);
}

fn sessionMatchesWindow(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    head: hash_mod.Hash,
    since_ms: ?i64,
    until_ms_exclusive: ?i64,
) !bool {
    if (since_ms == null and until_ms_exclusive == null) return true;

    var current: ?hash_mod.Hash = head;
    while (current) |cursor| {
        var parsed = try store.readStep(io, gpa, cursor);
        defer parsed.deinit();
        const step = parsed.value;
        const matches_since = since_ms == null or step.timestamp >= since_ms.?;
        const matches_until = until_ms_exclusive == null or step.timestamp < until_ms_exclusive.?;
        if (matches_since and matches_until) return true;
        current = if (step.parent) |parent| try hash_mod.Hash.fromHex(parent) else null;
    }
    return false;
}

fn collectReachableObjects(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    selected: []const SelectedRef,
) ![]const ObjectLink {
    var seen = std.StringHashMap(void).init(gpa);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        seen.deinit();
    }

    var stack: std.ArrayList([]u8) = .empty;
    defer {
        for (stack.items) |item| gpa.free(item);
        stack.deinit(gpa);
    }

    var objects: std.ArrayList(ObjectLink) = .empty;
    errdefer {
        for (objects.items) |*object_link| object_link.deinit(gpa);
        objects.deinit(gpa);
    }

    for (selected) |ref| {
        try stack.append(gpa, try gpa.dupe(u8, ref.head_hash));
    }

    while (stack.pop()) |hex_hash| {
        defer gpa.free(hex_hash);
        if (seen.contains(hex_hash)) continue;
        try seen.put(try gpa.dupe(u8, hex_hash), {});

        const hash = try hash_mod.Hash.fromHex(hex_hash);
        const raw = try store.readBlob(io, gpa, hash);
        defer gpa.free(raw);

        const kind = object_mod.detectKind(raw);
        try objects.append(gpa, .{
            .hash = try gpa.dupe(u8, hex_hash),
            .kind = kind,
            .size = raw.len,
            .path = try objectPathAlloc(gpa, hex_hash),
        });

        if (std.mem.eql(u8, kind, "step")) {
            var parsed_step = try std.json.parseFromSlice(store_mod.Step, gpa, raw, .{
                .allocate = .alloc_always,
            });
            defer parsed_step.deinit();
            if (parsed_step.value.parent) |parent| {
                try stack.append(gpa, try gpa.dupe(u8, parent));
            }
            try stack.append(gpa, try gpa.dupe(u8, parsed_step.value.tree));
            continue;
        }
        if (std.mem.eql(u8, kind, "tree")) {
            var parsed_tree = try std.json.parseFromSlice(store_mod.Tree, gpa, raw, .{
                .allocate = .alloc_always,
            });
            defer parsed_tree.deinit();
            for (parsed_tree.value.entries) |entry| {
                try stack.append(gpa, try gpa.dupe(u8, entry.blob));
            }
            continue;
        }
        if (std.mem.eql(u8, kind, "blame")) {
            var parsed_blame = try std.json.parseFromSlice(blame_mod.BlameMap, gpa, raw, .{
                .allocate = .alloc_always,
            });
            defer parsed_blame.deinit();
            for (parsed_blame.value.lines) |line| {
                try stack.append(gpa, try gpa.dupe(u8, line.step));
            }
        }
    }

    std.mem.sort(ObjectLink, objects.items, {}, lessThanObjectLink);
    return objects.toOwnedSlice(gpa);
}

fn lessThanObjectLink(_: void, a: ObjectLink, b: ObjectLink) bool {
    return std.mem.lessThan(u8, a.hash, b.hash);
}

fn freeObjectLinks(gpa: std.mem.Allocator, objects: []const ObjectLink) void {
    for (objects) |object_link| object_link.deinit(gpa);
    gpa.free(objects);
}

fn buildManifestRefs(gpa: std.mem.Allocator, selected: []const SelectedRef) ![]const ManifestRef {
    const refs = try gpa.alloc(ManifestRef, selected.len);
    var initialized: usize = 0;
    errdefer {
        for (refs[0..initialized]) |ref| {
            gpa.free(@constCast(ref.path));
            gpa.free(@constCast(ref.origin));
            gpa.free(@constCast(ref.session_id));
            gpa.free(@constCast(ref.head_hash));
        }
        gpa.free(refs);
    }

    for (selected, 0..) |ref, i| {
        refs[i] = .{
            .path = try gpa.dupe(u8, ref.path),
            .origin = try gpa.dupe(u8, ref.origin),
            .session_id = try gpa.dupe(u8, ref.session_id),
            .head_hash = try gpa.dupe(u8, ref.head_hash),
        };
        initialized = i + 1;
    }
    return refs;
}

fn buildManifestObjects(gpa: std.mem.Allocator, objects: []const ObjectLink) ![]const ManifestObject {
    const manifest_objects = try gpa.alloc(ManifestObject, objects.len);
    var initialized: usize = 0;
    errdefer {
        for (manifest_objects[0..initialized]) |object_entry| {
            gpa.free(@constCast(object_entry.hash));
            gpa.free(@constCast(object_entry.path));
        }
        gpa.free(manifest_objects);
    }

    for (objects, 0..) |object_link, i| {
        manifest_objects[i] = .{
            .hash = try gpa.dupe(u8, object_link.hash),
            .kind = object_link.kind,
            .size = object_link.size,
            .path = try gpa.dupe(u8, object_link.path),
        };
        initialized = i + 1;
    }
    return manifest_objects;
}

fn freeManifestObjects(gpa: std.mem.Allocator, objects: []const ManifestObject) void {
    for (objects) |object_entry| {
        gpa.free(@constCast(object_entry.hash));
        gpa.free(@constCast(object_entry.path));
    }
    gpa.free(objects);
}

fn ensureBundleDir(io: std.Io, path: []const u8) !std.Io.Dir {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, path);

    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    var iter = dir.iterate();
    if (try iter.next(io)) |_| {
        dir.close(io);
        return error.BundlePathNotEmpty;
    }
    return dir;
}

fn writeFileAtomic(io: std.Io, dir: std.Io.Dir, rel_path: []const u8, content: []const u8) !void {
    const parent = std.fs.path.dirname(rel_path);
    if (parent) |parent_path| {
        if (parent_path.len > 0) try dir.createDirPath(io, parent_path);
    }
    var atomic = try dir.createFileAtomic(io, rel_path, .{ .replace = true, .make_path = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, content);
    try fs_mod.atomicReplace(io, &atomic);
}

fn writeJsonAtomic(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, rel_path: []const u8, value: anytype) !void {
    var writer = std.Io.Writer.Allocating.init(gpa);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    try writeFileAtomic(io, dir, rel_path, writer.writer.buffered());
}

fn validateManifest(gpa: std.mem.Allocator, manifest: *const Manifest) !void {
    if (!std.mem.eql(u8, manifest.bundle_format, bundle_format)) return error.UnsupportedBundleFormat;
    _ = try hash_mod.Hash.fromHex(manifest.bundle_id);
    if (manifest.encryption != null) return error.UnsupportedBundleEncryption;
    if (manifest.refs.len == 0) return error.BundleMissingRefs;
    if (manifest.objects.len == 0) return error.BundleMissingObjects;

    for (manifest.refs) |ref_entry| {
        if (!isSafeRelativePath(ref_entry.path)) return error.BundlePathInvalid;
        const expected_path = try ref_mod.buildRefPath(gpa, ref_entry.origin, ref_entry.session_id);
        defer gpa.free(expected_path);
        if (!std.mem.eql(u8, expected_path, ref_entry.path)) return error.BundleRefPathInvalid;
        _ = try hash_mod.Hash.fromHex(ref_entry.head_hash);
    }

    for (manifest.objects) |object_entry| {
        if (!isSafeRelativePath(object_entry.path)) return error.BundlePathInvalid;
        const expected_path = try objectPathAlloc(gpa, object_entry.hash);
        defer gpa.free(expected_path);
        if (!std.mem.eql(u8, expected_path, object_entry.path)) return error.BundleObjectPathInvalid;
        _ = try hash_mod.Hash.fromHex(object_entry.hash);
    }
}

fn validatePrivacyReportPath(
    gpa: std.mem.Allocator,
    io: std.Io,
    bundle_dir: std.Io.Dir,
    manifest: *const Manifest,
) !void {
    if (manifest.privacy.report_path) |path| {
        if (!isSafeRelativePath(path)) return error.BundlePathInvalid;
        const report = try bundle_dir.readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(report);
    }
}

fn validateBundleObjects(
    io: std.Io,
    gpa: std.mem.Allocator,
    bundle_dir: std.Io.Dir,
    manifest: *const Manifest,
) !void {
    var object_map = std.StringHashMap(ManifestObject).init(gpa);
    defer object_map.deinit();
    var ref_map = std.StringHashMap(void).init(gpa);
    defer ref_map.deinit();

    for (manifest.objects) |object_entry| {
        const existing = try object_map.getOrPut(object_entry.hash);
        if (existing.found_existing) return error.BundleDuplicateObject;
        existing.value_ptr.* = object_entry;

        const raw = try bundle_dir.readFileAlloc(io, object_entry.path, gpa, .unlimited);
        defer gpa.free(raw);
        if (raw.len != object_entry.size) return error.BundleObjectSizeMismatch;
        const actual = hash_mod.Hash.ofBytes(raw).toHex();
        if (!std.mem.eql(u8, &actual, object_entry.hash)) return error.BundleHashMismatch;
        if (!std.mem.eql(u8, object_mod.detectKind(raw), object_entry.kind)) return error.BundleKindMismatch;
    }

    for (manifest.refs) |ref_entry| {
        const existing = try ref_map.getOrPut(ref_entry.path);
        if (existing.found_existing) return error.BundleDuplicateRef;
        if (!object_map.contains(ref_entry.head_hash)) return error.BundleMissingHeadObject;
    }

    for (manifest.objects) |object_entry| {
        const raw = try bundle_dir.readFileAlloc(io, object_entry.path, gpa, .unlimited);
        defer gpa.free(raw);
        try validateObjectReachability(gpa, &object_map, object_entry.kind, raw);
    }
}

fn buildObjectMap(gpa: std.mem.Allocator, manifest: *const Manifest) !std.StringHashMap(ManifestObject) {
    var object_map = std.StringHashMap(ManifestObject).init(gpa);
    errdefer object_map.deinit();
    for (manifest.objects) |object_entry| {
        try object_map.put(object_entry.hash, object_entry);
    }
    return object_map;
}

fn validateObjectReachability(
    gpa: std.mem.Allocator,
    object_map: *const std.StringHashMap(ManifestObject),
    kind: []const u8,
    raw: []const u8,
) !void {
    if (std.mem.eql(u8, kind, "step")) {
        var parsed_step = try std.json.parseFromSlice(store_mod.Step, gpa, raw, .{
            .allocate = .alloc_always,
        });
        defer parsed_step.deinit();
        if (parsed_step.value.parent) |parent| {
            if (!object_map.contains(parent)) return error.BundleReachabilityMissingObject;
        }
        if (!object_map.contains(parsed_step.value.tree)) return error.BundleReachabilityMissingObject;
        return;
    }
    if (std.mem.eql(u8, kind, "tree")) {
        var parsed_tree = try std.json.parseFromSlice(store_mod.Tree, gpa, raw, .{
            .allocate = .alloc_always,
        });
        defer parsed_tree.deinit();
        for (parsed_tree.value.entries) |entry| {
            if (!object_map.contains(entry.blob)) return error.BundleReachabilityMissingObject;
        }
        return;
    }
    if (std.mem.eql(u8, kind, "blame")) {
        var parsed_blame = try std.json.parseFromSlice(blame_mod.BlameMap, gpa, raw, .{
            .allocate = .alloc_always,
        });
        defer parsed_blame.deinit();
        for (parsed_blame.value.lines) |line| {
            if (!object_map.contains(line.step)) return error.BundleReachabilityMissingObject;
        }
    }
}

fn shouldReplaceRef(replace_refs: []const SessionFilter, origin: []const u8, session_id: []const u8) bool {
    for (replace_refs) |ref_filter| {
        if (std.mem.eql(u8, ref_filter.origin, origin) and std.mem.eql(u8, ref_filter.session_id, session_id)) return true;
    }
    return false;
}

test "shouldReplaceRef with empty slice returns false" {
    try std.testing.expect(!shouldReplaceRef(&.{}, "origin1", "session1"));
}

test "shouldReplaceRef with matching entry returns true" {
    const filters = [_]SessionFilter{.{
        .origin = "origin1",
        .session_id = "session1",
    }};
    try std.testing.expect(shouldReplaceRef(&filters, "origin1", "session1"));
}

test "shouldReplaceRef with one non-matching and one matching entry returns true" {
    const filters = [_]SessionFilter{
        .{ .origin = "origin1", .session_id = "session1" },
        .{ .origin = "origin2", .session_id = "session2" },
    };
    try std.testing.expect(shouldReplaceRef(&filters, "origin2", "session2"));
}

test "shouldReplaceRef with matching origin but different session_id returns false" {
    const filters = [_]SessionFilter{.{
        .origin = "origin1",
        .session_id = "session1",
    }};
    try std.testing.expect(!shouldReplaceRef(&filters, "origin1", "session_different"));
}

fn namespacedSessionIdAlloc(gpa: std.mem.Allocator, session_id: []const u8, bundle_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}@import-{s}", .{ session_id, bundle_id[0..12] });
}

fn cloneNamespacedSessionChain(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    bundle_dir: std.Io.Dir,
    object_map: *const std.StringHashMap(ManifestObject),
    original_head_hash: []const u8,
    namespaced_session_id: []const u8,
    result: *ImportResult,
) !hash_mod.Hash {
    var cloned = std.StringHashMap([]u8).init(gpa);
    defer {
        var it = cloned.valueIterator();
        while (it.next()) |value| gpa.free(value.*);
        cloned.deinit();
    }
    const rewritten = try cloneStepHash(io, gpa, store, bundle_dir, object_map, original_head_hash, namespaced_session_id, &cloned, result);
    return hash_mod.Hash.fromHex(rewritten);
}

fn cloneStepHash(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    bundle_dir: std.Io.Dir,
    object_map: *const std.StringHashMap(ManifestObject),
    original_hash: []const u8,
    namespaced_session_id: []const u8,
    cloned: *std.StringHashMap([]u8),
    result: *ImportResult,
) ![]const u8 {
    if (cloned.get(original_hash)) |existing| return existing;

    const object_entry = object_map.get(original_hash) orelse return error.BundleReachabilityMissingObject;
    if (!std.mem.eql(u8, object_entry.kind, "step")) return error.BundleRefConflict;

    const raw = try bundle_dir.readFileAlloc(io, object_entry.path, gpa, .unlimited);
    defer gpa.free(raw);

    var parsed_step = try std.json.parseFromSlice(store_mod.Step, gpa, raw, .{
        .allocate = .alloc_always,
    });
    defer parsed_step.deinit();

    var parent_hex_buf: [hash_mod.hex_len]u8 = undefined;
    const rewritten_parent: ?[]const u8 = if (parsed_step.value.parent) |parent| blk: {
        const rewritten = try cloneStepHash(io, gpa, store, bundle_dir, object_map, parent, namespaced_session_id, cloned, result);
        @memcpy(&parent_hex_buf, rewritten);
        break :blk parent_hex_buf[0..];
    } else null;

    const rewritten_step = store_mod.Step{
        .parent = rewritten_parent,
        .tree = parsed_step.value.tree,
        .session_id = namespaced_session_id,
        .origin = parsed_step.value.origin,
        .turn_id = parsed_step.value.turn_id,
        .causes = parsed_step.value.causes,
        .timestamp = parsed_step.value.timestamp,
        .messages = parsed_step.value.messages,
        .tool_calls = parsed_step.value.tool_calls,
    };
    const written = try object_mod.writeStepDetailed(io, store.root, gpa, rewritten_step);
    const written_hex = written.hash.toHex();
    const owned = try gpa.dupe(u8, &written_hex);
    try cloned.put(original_hash, owned);
    result.cloned_steps += 1;
    return owned;
}

fn listRefSessions(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store) ![]const RefIdent {
    var list: std.ArrayList(RefIdent) = .empty;
    errdefer {
        for (list.items) |*ref_ident| ref_ident.deinit(gpa);
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
        try list.append(gpa, .{
            .origin = try ref_mod.decodePathComponentAlloc(gpa, entry.path[0..sep]),
            .session_id = try ref_mod.decodePathComponentAlloc(gpa, entry.path[sep + 1 ..]),
        });
    }
    std.mem.sort(RefIdent, list.items, {}, lessThanRefIdent);
    return list.toOwnedSlice(gpa);
}

fn lessThanRefIdent(_: void, a: RefIdent, b: RefIdent) bool {
    if (std.mem.eql(u8, a.origin, b.origin)) return std.mem.lessThan(u8, a.session_id, b.session_id);
    return std.mem.lessThan(u8, a.origin, b.origin);
}

fn freeRefIdents(gpa: std.mem.Allocator, idents: []const RefIdent) void {
    for (idents) |ident| ident.deinit(gpa);
    gpa.free(idents);
}

fn computeBundleId(
    gpa: std.mem.Allocator,
    selected: []const SelectedRef,
    created_at_ms: i64,
) ![hash_mod.hex_len]u8 {
    var seed = std.ArrayList(u8).empty;
    defer seed.deinit(gpa);

    var ts_buf: [32]u8 = undefined;
    const ts = try std.fmt.bufPrint(&ts_buf, "{d}", .{created_at_ms});
    try seed.appendSlice(gpa, ts);
    for (selected) |ref| {
        try seed.appendSlice(gpa, ref.path);
        try seed.append(gpa, 0);
        try seed.appendSlice(gpa, ref.head_hash);
        try seed.append(gpa, '\n');
    }
    return hash_mod.Hash.ofBytes(seed.items).toHex();
}

test "computeBundleId is deterministic with same inputs" {
    const origin = try std.testing.allocator.dupe(u8, "origin");
    defer std.testing.allocator.free(origin);
    const session_id = try std.testing.allocator.dupe(u8, "session");
    defer std.testing.allocator.free(session_id);
    const path = try std.testing.allocator.dupe(u8, "refs/sessions/origin/session");
    defer std.testing.allocator.free(path);
    const head_hash = try std.testing.allocator.dupe(u8, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    defer std.testing.allocator.free(head_hash);

    var selected = [_]SelectedRef{
        .{
            .origin = origin,
            .session_id = session_id,
            .path = path,
            .head_hash = head_hash,
        },
    };
    const created_at_ms: i64 = 1234567890;

    const hash1 = try computeBundleId(std.testing.allocator, &selected, created_at_ms);
    const hash2 = try computeBundleId(std.testing.allocator, &selected, created_at_ms);
    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "computeBundleId differs with different created_at_ms" {
    const origin = try std.testing.allocator.dupe(u8, "origin");
    defer std.testing.allocator.free(origin);
    const session_id = try std.testing.allocator.dupe(u8, "session");
    defer std.testing.allocator.free(session_id);
    const path = try std.testing.allocator.dupe(u8, "refs/sessions/origin/session");
    defer std.testing.allocator.free(path);
    const head_hash = try std.testing.allocator.dupe(u8, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    defer std.testing.allocator.free(head_hash);

    var selected = [_]SelectedRef{
        .{
            .origin = origin,
            .session_id = session_id,
            .path = path,
            .head_hash = head_hash,
        },
    };

    const hash1 = try computeBundleId(std.testing.allocator, &selected, 1000);
    const hash2 = try computeBundleId(std.testing.allocator, &selected, 2000);
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

fn objectPathAlloc(gpa: std.mem.Allocator, hex_hash: []const u8) ![]u8 {
    if (hex_hash.len != hash_mod.hex_len) return error.InvalidHash;
    return std.fmt.allocPrint(gpa, "objects/{s}/{s}", .{ hex_hash[0..2], hex_hash[2..] });
}

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

test "isSafeRelativePath accepts valid safe paths" {
    try std.testing.expect(isSafeRelativePath("objects/ab/cdef"));
    try std.testing.expect(isSafeRelativePath("a"));
}

test "isSafeRelativePath rejects empty path" {
    try std.testing.expect(!isSafeRelativePath(""));
}

test "isSafeRelativePath rejects absolute path" {
    try std.testing.expect(!isSafeRelativePath("/etc/passwd"));
}

test "isSafeRelativePath rejects parent-dir segment at start" {
    try std.testing.expect(!isSafeRelativePath("../escape"));
}

test "isSafeRelativePath rejects parent-dir segment in middle" {
    try std.testing.expect(!isSafeRelativePath("a/../b"));
}

test "isSafeRelativePath rejects current-dir segment" {
    try std.testing.expect(!isSafeRelativePath("a/./b"));
}

test "isSafeRelativePath rejects double slash (empty segment)" {
    try std.testing.expect(!isSafeRelativePath("a//b"));
}

test "isSafeRelativePath rejects trailing slash" {
    try std.testing.expect(!isSafeRelativePath("a/"));
}

test "namespacedSessionIdAlloc appends bundle prefix" {
    const value = try namespacedSessionIdAlloc(std.testing.allocator, "sess", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("sess@import-0123456789ab", value);
}

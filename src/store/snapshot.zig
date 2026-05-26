const std = @import("std");
const hash_mod = @import("hash.zig");
const index_mod = @import("index.zig");
const object = @import("object.zig");
const ignore_mod = @import("ignore.zig");
const buf_pool_mod = @import("../util/buf_pool.zig");
const file_limits_mod = @import("../util/file_limits.zig");
const fs_mod = @import("../util/fs.zig");

pub const Hash = hash_mod.Hash;
pub const Ignorer = ignore_mod.Ignorer;
const BufPool = buf_pool_mod.BufPool;
const binary_probe_bytes: usize = 8 * 1024;
const initial_read_bytes: usize = 8 * 1024;

/// Configuration for a workspace snapshot.
pub const SnapshotConfig = struct {
    /// Files larger than this byte threshold are skipped.
    large_file_bytes: u64 = 16 * 1024 * 1024,
};

/// Returns true when `data` looks like binary content.
///
/// Uses the same heuristic as Git: if any of the first 8 KiB contain a NUL
/// byte, the file is treated as binary.
pub fn isBinary(data: []const u8) bool {
    const probe = data[0..@min(data.len, 8192)];
    return std.mem.indexOfScalar(u8, probe, 0) != null;
}

/// Walk `repo_dir` and write a snapshot Tree object to the store.
///
/// Returns the Tree hash.  Paths are workspace-relative.  The following are
/// always excluded: ignored directories, ignored files (secrets/credentials),
/// symlinks, binary files, and files larger than `config.large_file_bytes`.
///
/// The tree entries are sorted by path before writing for deterministic hashes.
pub fn snapshot(
    io: std.Io,
    repo_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    store_root: std.Io.Dir,
    index: ?*index_mod.Index,
    ignorer: *const Ignorer,
    config: SnapshotConfig,
) !Hash {
    const max_file_bytes = file_limits_mod.effectiveMaxFileBytes(config.large_file_bytes);

    // Entries accumulate as we walk; paths are heap-allocated and owned here.
    var entries: std.ArrayList(object.TreeEntry) = .empty;
    defer {
        for (entries.items) |e| {
            gpa.free(@constCast(e.path));
            gpa.free(@constCast(e.blob));
        }
        entries.deinit(gpa);
    }

    var pool = BufPool.init(gpa);
    defer pool.deinit();

    var walkable = try repo_dir.openDir(io, ".", .{ .iterate = true });
    defer walkable.close(io);

    var walker = try walkable.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (ignorer.shouldIgnoreDir(entry.basename)) {
                walker.leave(io);
            }
            continue;
        }
        if (entry.kind != .file) continue; // skip symlinks and other types

        if (ignorer.shouldIgnoreFile(entry.basename)) continue;

        const loaded = loadTextFile(io, entry.dir, entry.basename, &pool, max_file_bytes) catch continue orelse continue;
        defer pool.release(loaded.buf);
        const data = loaded.buf[0..loaded.size];

        const blob_write = try object.writeDetailed(io, store_root, data);
        const blob_hash = blob_write.hash;
        const blob_hex = blob_hash.toHex();
        if (index) |idx| {
            try idx.insertObject(&blob_hex, "blob", blob_write.size);
        }

        const norm_path = try gpa.dupe(u8, entry.path);
        if (comptime std.fs.path.sep != '/') {
            for (norm_path) |*c| if (c.* == std.fs.path.sep) {
                c.* = '/';
            };
        }
        try entries.append(gpa, .{
            .path = norm_path,
            .blob = try gpa.dupe(u8, &blob_hex),
            .mode = "file", // executable-bit tracking deferred to a future phase
            .size = loaded.size,
        });
    }

    // Deterministic ordering is required for reproducible tree hashes.
    std.mem.sort(object.TreeEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: object.TreeEntry, b: object.TreeEntry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    const tree = object.Tree{ .entries = entries.items };
    const tree_write = try object.writeTreeDetailed(io, store_root, gpa, tree);
    const tree_hex = tree_write.hash.toHex();
    if (index) |idx| {
        try idx.insertObject(&tree_hex, "tree", tree_write.size);
    }
    return tree_write.hash;
}

const LoadedTextFile = struct {
    buf: []u8,
    size: u64,
};

fn loadTextFile(
    io: std.Io,
    dir: std.Io.Dir,
    basename: []const u8,
    pool: *BufPool,
    max_file_bytes: u64,
) !?LoadedTextFile {
    var file = dir.openFile(io, basename, .{}) catch return null;
    defer file.close(io);

    const max_bytes: usize = std.math.cast(usize, max_file_bytes) orelse return null;
    var buf = try pool.acquire(@min(initial_read_bytes, max_bytes));
    errdefer pool.release(buf);

    var reader_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buf);
    var used: usize = 0;

    while (true) {
        if (used == buf.len and used < max_bytes) {
            const next_hint = @min(max_bytes, buf.len * 2);
            var bigger = try pool.acquire(next_hint);
            @memcpy(bigger[0..used], buf[0..used]);
            pool.release(buf);
            buf = bigger;
        }

        const remaining_allowed = max_bytes - used;
        if (remaining_allowed == 0) {
            var overflow: [1]u8 = undefined;
            const overflow_n = try reader.interface.readSliceShort(&overflow);
            if (overflow_n > 0) {
                pool.release(buf);
                return null;
            }
            break;
        }

        const chunk_len = @min(buf.len - used, remaining_allowed);
        const start = used;
        const n = try reader.interface.readSliceShort(buf[used .. used + chunk_len]);
        if (n == 0) break;
        used += n;

        const probed_before = @min(start, binary_probe_bytes);
        const probed_after = @min(used, binary_probe_bytes);
        if (probed_after > probed_before and isBinary(buf[0..probed_after])) {
            pool.release(buf);
            return null;
        }
    }

    return .{
        .buf = buf,
        .size = used,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

/// Helper: write a text file at `rel_path` (e.g. "src/foo.zig") inside `dir`,
/// creating intermediate directories as needed.
fn writeTestFile(io: std.Io, dir: std.Io.Dir, rel_path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |sep| {
        try dir.createDirPath(io, rel_path[0..sep]);
    }
    var af = try dir.createFileAtomic(io, rel_path, .{ .replace = true, .make_path = false });
    try af.file.writeStreamingAll(io, content);
    try fs_mod.atomicReplace(io, &af);
}

test "isBinary: text is not binary" {
    try std.testing.expect(!isBinary("hello\nworld\n"));
}

test "isBinary: data with NUL is binary" {
    try std.testing.expect(isBinary("hello\x00world"));
}

test "snapshot: captures text files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "src/main.zig", "pub fn main() void {}");
    try writeTestFile(io, tmp.dir, "README.md", "# hello");
    // .agit/ is the store root — it should be excluded automatically.
    try tmp.dir.createDirPath(io, ".agit/objects");

    const ignorer = Ignorer.initDefault(gpa);
    const h = try snapshot(io, tmp.dir, gpa, tmp.dir, null, &ignorer, .{});

    var parsed = try object.readTree(io, tmp.dir, gpa, h);
    defer parsed.deinit();

    // Two text files should be captured; the .agit tree is excluded.
    try std.testing.expectEqual(@as(usize, 2), parsed.value.entries.len);
    // Entries must be sorted by path.
    try std.testing.expect(
        std.mem.lessThan(u8, parsed.value.entries[0].path, parsed.value.entries[1].path),
    );
}

test "snapshot: excludes ignored directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "src/main.zig", "code");
    try writeTestFile(io, tmp.dir, "node_modules/lib/index.js", "library");
    try tmp.dir.createDirPath(io, ".agit/objects");

    const ignorer = Ignorer.initDefault(gpa);
    const h = try snapshot(io, tmp.dir, gpa, tmp.dir, null, &ignorer, .{});

    var parsed = try object.readTree(io, tmp.dir, gpa, h);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try std.testing.expectEqualStrings("src/main.zig", parsed.value.entries[0].path);
}

test "snapshot: excludes secret files and binary files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "safe.txt", "okay");
    try writeTestFile(io, tmp.dir, ".env", "SECRET=123");
    try writeTestFile(io, tmp.dir, "binary.bin", "data\x00raw");
    try tmp.dir.createDirPath(io, ".agit/objects");

    const ignorer = Ignorer.initDefault(gpa);
    const h = try snapshot(io, tmp.dir, gpa, tmp.dir, null, &ignorer, .{});

    var parsed = try object.readTree(io, tmp.dir, gpa, h);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try std.testing.expectEqualStrings("safe.txt", parsed.value.entries[0].path);
}

test "snapshot: deterministic hash for identical content" {
    var tmp1 = std.testing.tmpDir(.{});
    defer tmp1.cleanup();
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const content = "hello world\n";
    try writeTestFile(io, tmp1.dir, "a.txt", content);
    try writeTestFile(io, tmp2.dir, "a.txt", content);
    try tmp1.dir.createDirPath(io, ".agit/objects");
    try tmp2.dir.createDirPath(io, ".agit/objects");

    const ignorer = Ignorer.initDefault(gpa);
    const h1 = try snapshot(io, tmp1.dir, gpa, tmp1.dir, null, &ignorer, .{});
    const h2 = try snapshot(io, tmp2.dir, gpa, tmp2.dir, null, &ignorer, .{});

    try std.testing.expect(h1.eql(h2));
}

test "snapshot: keeps files at the cap and skips files above it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const cap: usize = 32;
    const exact = try gpa.alloc(u8, cap);
    defer gpa.free(exact);
    @memset(exact, 'a');

    const over = try gpa.alloc(u8, cap + 1);
    defer gpa.free(over);
    @memset(over, 'b');

    try writeTestFile(io, tmp.dir, "exact.txt", exact);
    try writeTestFile(io, tmp.dir, "over.txt", over);
    try tmp.dir.createDirPath(io, ".agit/objects");

    const ignorer = Ignorer.initDefault(gpa);
    const h = try snapshot(io, tmp.dir, gpa, tmp.dir, null, &ignorer, .{
        .large_file_bytes = cap,
    });

    var parsed = try object.readTree(io, tmp.dir, gpa, h);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try std.testing.expectEqualStrings("exact.txt", parsed.value.entries[0].path);
    try std.testing.expectEqual(@as(u64, cap), parsed.value.entries[0].size);
}

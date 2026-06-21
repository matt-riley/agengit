const std = @import("std");
const store_mod = @import("store.zig");
const blame_mod = @import("blame.zig");
const index_mod = @import("index.zig");
const snapshot_mod = @import("snapshot.zig");

const Store = store_mod.Store;
const Hash = store_mod.Hash;
const BlameMap = store_mod.BlameMap;

const PendingBlameRow = struct {
    path: []const u8,
    blame_hex: [64]u8,
    blob_hex: [64]u8,
};

const LoadedPriorBlame = struct {
    lines: []const []const u8,
    blame: BlameMap,
};

/// Compute and persist incremental blame for every changed text file in the
/// given step's tree.  Blame objects are written content-addressed; the
/// per-step `blame_maps` rows are inserted in a single transaction so a
/// failure leaves no partial linkage.  Shared by finalize and reindex.
pub fn recordStepBlame(self: *Store, io: std.Io, gpa: std.mem.Allocator, input: Store.StepBlameInput) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tree_hash = try Hash.fromHex(input.tree_hash);
    var tree_parsed = try self.readTree(io, arena, tree_hash);
    defer tree_parsed.deinit();

    var pending: std.ArrayList(PendingBlameRow) = .empty;

    for (tree_parsed.value.entries) |entry| {
        if (entry.blob.len != 64) continue;
        if (entry.size > input.max_file_bytes) continue;

        const latest = try self.index.queryLatestBlame(entry.path);
        if (latest) |prior| {
            // Unchanged since the last recorded version: the latest row is
            // still correct, so skip without reading the blob.
            if (std.mem.eql(u8, entry.blob, prior.blob_hash[0..])) continue;
        }

        const new_blob_hash = try Hash.fromHex(entry.blob);
        const new_blob = self.readBlob(io, arena, new_blob_hash) catch |err| {
            try self.setBlameNeedsReindex(true);
            return err;
        };
        if (new_blob.len > input.max_file_bytes) continue;
        if (snapshot_mod.isBinary(new_blob)) continue;
        if (snapshot_mod.isSnapshotPlaceholder(new_blob)) continue;

        const new_lines = try snapshot_mod.splitLines(arena, new_blob);

        var old_lines: []const []const u8 = &.{};
        var old_blame: ?BlameMap = null;
        if (latest) |prior| {
            const loaded = loadPriorBlame(self, io, arena, prior) catch |err| {
                try self.setBlameNeedsReindex(true);
                return err;
            };
            if (loaded.lines.len == loaded.blame.lines.len) {
                old_lines = loaded.lines;
                old_blame = loaded.blame;
            } else {
                try self.setBlameNeedsReindex(true);
                return error.BlameLengthMismatch;
            }
        }

        const bm = try blame_mod.computeBlame(arena, entry.path, old_lines, new_lines, old_blame, input.step_hash);
        const blame_hash = try self.writeBlame(io, arena, bm);

        var row: PendingBlameRow = .{ .path = entry.path, .blame_hex = blame_hash.toHex(), .blob_hex = undefined };
        @memcpy(row.blob_hex[0..], entry.blob);
        try pending.append(arena, row);

        if (input.max_changed_files != 0 and pending.items.len > input.max_changed_files) {
            return error.BlameChangeLimitExceeded;
        }
    }

    if (pending.items.len == 0) return;

    try self.index.db.transaction();
    errdefer self.index.db.rollback();
    for (pending.items) |row| {
        try self.index.insertBlameMap(
            row.path,
            input.step_hash,
            row.blame_hex[0..],
            row.blob_hex[0..],
            input.session_origin,
            input.session_id,
            input.timestamp,
        );
    }
    try self.index.db.commit();
}

fn loadPriorBlame(self: *Store, io: std.Io, arena: std.mem.Allocator, prior: index_mod.Index.BlameRow) !LoadedPriorBlame {
    const blob_hash = try Hash.fromHex(prior.blob_hash[0..]);
    const blob = try self.readBlob(io, arena, blob_hash);
    if (snapshot_mod.isBinary(blob) or snapshot_mod.isSnapshotPlaceholder(blob)) return error.PriorBlobNotText;
    const lines = try snapshot_mod.splitLines(arena, blob);

    const blame_hash = try Hash.fromHex(prior.blame_hash[0..]);
    const blame_data = try self.readBlob(io, arena, blame_hash);
    const parsed = try std.json.parseFromSlice(BlameMap, arena, blame_data, .{ .allocate = .alloc_always });
    return .{ .lines = lines, .blame = parsed.value };
}

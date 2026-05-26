const std = @import("std");
const test_support = @import("test_support");
const snapshot_mod = test_support.snapshot;
const diff_mod = test_support.diff;
const blame_mod = test_support.blame;

const Ignorer = snapshot_mod.Ignorer;

const repo_file_count: usize = 1000;
const repo_file_bytes: usize = 4096;
const diff_iterations: usize = 250;
const blame_iterations: usize = 250;

test "bench store hot paths" {
    try benchSnapshot();
    try benchDiff();
    try benchBlame();
}

fn benchSnapshot() !void {
    const io = std.testing.io;
    const gpa = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "store");

    var repo_dir = try tmp.dir.openDir(io, "repo", .{});
    defer repo_dir.close(io);
    var store_dir = try tmp.dir.openDir(io, "store", .{});
    defer store_dir.close(io);

    try populateRepo(io, repo_dir);

    const ignorer = Ignorer.initDefault(gpa);
    const start = std.Io.Timestamp.now(io, .awake);
    _ = try snapshot_mod.snapshot(io, repo_dir, gpa, store_dir, null, &ignorer, .{});
    const total_us = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMicroseconds();

    std.debug.print(
        "bench-store:snapshot files={d} bytes_per_file={d} total_us={d}\n",
        .{ repo_file_count, repo_file_bytes, total_us },
    );
}

fn benchDiff() !void {
    const io = std.testing.io;
    const gpa = std.heap.page_allocator;

    const old_lines = try makeLines(gpa, 600, "before");
    defer freeLines(gpa, old_lines);
    const new_lines = try makeLines(gpa, 600, "after");
    defer freeLines(gpa, new_lines);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const start = std.Io.Timestamp.now(io, .awake);
    for (0..diff_iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const edits = try diff_mod.diff(arena.allocator(), old_lines, new_lines);
        std.mem.doNotOptimizeAway(edits.len);
    }
    const total_us = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMicroseconds();
    const per_iter_us = @divTrunc(total_us, @as(i64, diff_iterations));

    std.debug.print(
        "bench-store:diff lines={d} iterations={d} total_us={d} per_iter_us={d}\n",
        .{ old_lines.len, diff_iterations, total_us, per_iter_us },
    );
}

fn benchBlame() !void {
    const io = std.testing.io;
    const gpa = std.heap.page_allocator;

    const old_lines = try makeLines(gpa, 600, "before");
    defer freeLines(gpa, old_lines);
    const new_lines = try makeLines(gpa, 620, "after");
    defer freeLines(gpa, new_lines);

    const base_blame = try blame_mod.computeBlame(gpa, "src/main.zig", &.{}, old_lines, null, "1" ** 64);
    defer blame_mod.freeBlameMap(gpa, base_blame);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const start = std.Io.Timestamp.now(io, .awake);
    for (0..blame_iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const blame = try blame_mod.computeBlame(
            arena.allocator(),
            "src/main.zig",
            old_lines,
            new_lines,
            base_blame,
            "2" ** 64,
        );
        std.mem.doNotOptimizeAway(blame.lines.len);
    }
    const total_us = start.durationTo(std.Io.Timestamp.now(io, .awake)).toMicroseconds();
    const per_iter_us = @divTrunc(total_us, @as(i64, blame_iterations));

    std.debug.print(
        "bench-store:blame lines={d}->{d} iterations={d} total_us={d} per_iter_us={d}\n",
        .{ old_lines.len, new_lines.len, blame_iterations, total_us, per_iter_us },
    );
}

fn populateRepo(io: std.Io, repo_dir: std.Io.Dir) !void {
    var content = [_]u8{'x'} ** repo_file_bytes;
    for (0..repo_file_count) |i| {
        var rel_buf: [64]u8 = undefined;
        const rel_path = try std.fmt.bufPrint(&rel_buf, "src/file-{d}.txt", .{i});
        try writeFile(io, repo_dir, rel_path, &content);
    }
}

fn writeFile(io: std.Io, dir: std.Io.Dir, rel_path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |sep| {
        try dir.createDirPath(io, rel_path[0..sep]);
    }
    var file = try dir.createFile(io, rel_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn makeLines(gpa: std.mem.Allocator, count: usize, prefix: []const u8) ![][]const u8 {
    const lines = try gpa.alloc([]const u8, count);
    errdefer gpa.free(lines);
    var built: usize = 0;
    errdefer {
        for (lines[0..built]) |line| gpa.free(@constCast(line));
    }

    for (0..count) |i| {
        lines[i] = try std.fmt.allocPrint(gpa, "{s}-{d}", .{ prefix, i });
        built += 1;
    }
    return lines;
}

fn freeLines(gpa: std.mem.Allocator, lines: [][]const u8) void {
    for (lines) |line| gpa.free(@constCast(line));
    gpa.free(lines);
}

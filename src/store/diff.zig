const std = @import("std");

/// The kind of edit applied to a single line.
pub const Op = enum { equal, insert, delete };

/// One unit in a diff between two sequences of lines.
pub const Edit = struct {
    op: Op,
    line: []const u8,
};

/// Compute the shortest edit script from `old` to `new` using Myers' algorithm.
///
/// Returns an allocator-owned slice of `Edit` values; caller must release it
/// with the same allocator, or reset/deinit the arena when using an arena
/// allocator. Line strings are borrowed from the input slices and must remain
/// valid for the lifetime of the result.
pub fn diff(
    allocator: std.mem.Allocator,
    old: []const []const u8,
    new: []const []const u8,
) ![]Edit {
    const n: isize = @intCast(old.len);
    const m: isize = @intCast(new.len);

    // Fast paths.
    if (n == 0 and m == 0) return &.{};
    if (n == 0) {
        const edits = try allocator.alloc(Edit, @intCast(m));
        for (new, 0..) |line, i| edits[i] = .{ .op = .insert, .line = line };
        return edits;
    }
    if (m == 0) {
        const edits = try allocator.alloc(Edit, @intCast(n));
        for (old, 0..) |line, i| edits[i] = .{ .op = .delete, .line = line };
        return edits;
    }

    const max: isize = n + m;
    const offset: usize = @intCast(max);
    const v_size: usize = @intCast(2 * max + 2);

    // V[k] = furthest x reached on diagonal k.
    const v = try allocator.alloc(isize, v_size);
    defer allocator.free(v);
    @memset(v, 0);

    // Store all trace snapshots in one allocation so callers can cheaply reuse
    // an arena across files instead of paying per-depth allocation churn.
    const trace = try allocator.alloc(isize, v_size * @as(usize, @intCast(max + 1)));
    defer allocator.free(trace);
    var trace_len: usize = 0;

    found: for (0..@as(usize, @intCast(max + 1))) |d_usize| {
        const d: isize = @intCast(d_usize);
        const trace_offset = trace_len * v_size;
        @memcpy(trace[trace_offset .. trace_offset + v_size], v);
        trace_len += 1;

        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const ki: usize = @intCast(@as(isize, @intCast(offset)) + k);
            // Determine the starting x on diagonal k without pre-computing
            // the disallowed index when k == ±d.
            var x: isize = blk: {
                if (k == -d) break :blk v[ki + 1]; // must insert
                if (k == d) break :blk v[ki - 1] + 1; // must delete
                if (v[ki - 1] < v[ki + 1]) break :blk v[ki + 1]; // insert better
                break :blk v[ki - 1] + 1; // delete better
            };
            var y: isize = x - k;
            // Extend along the diagonal (equal lines).
            while (x < n and y < m and
                std.mem.eql(u8, old[@intCast(x)], new[@intCast(y)]))
            {
                x += 1;
                y += 1;
            }
            v[ki] = x;
            if (x >= n and y >= m) break :found;
        }
    }

    // Backtrack through the trace to reconstruct the edit script in reverse.
    var edits_rev: std.ArrayList(Edit) = .empty;
    defer edits_rev.deinit(allocator);

    var x: isize = n;
    var y: isize = m;

    var d: isize = @intCast(trace_len - 1);
    while (d >= 1) : (d -= 1) {
        const trace_offset = @as(usize, @intCast(d)) * v_size;
        const v_prev = trace[trace_offset .. trace_offset + v_size]; // V state before step d
        const k: isize = x - y;
        const ki: usize = @intCast(@as(isize, @intCast(offset)) + k);

        // Reproduce the same branching decision used during the forward pass.
        const came_from_insert = blk: {
            if (k == -d) break :blk true;
            if (k == d) break :blk false;
            break :blk v_prev[ki - 1] < v_prev[ki + 1];
        };

        const prev_k = if (came_from_insert) k + 1 else k - 1;
        const prev_ki: usize = @intCast(@as(isize, @intCast(offset)) + prev_k);
        const prev_x = v_prev[prev_ki];
        // Starting x of the snake that follows the non-diagonal move.
        const snake_x0: isize = if (came_from_insert) prev_x else prev_x + 1;

        // Emit equal lines that were consumed by the snake (reversed order).
        while (x > snake_x0) {
            x -= 1;
            y -= 1;
            try edits_rev.append(allocator, .{ .op = .equal, .line = old[@intCast(x)] });
        }

        // Emit the single insert or delete.
        if (came_from_insert) {
            y -= 1;
            try edits_rev.append(allocator, .{ .op = .insert, .line = new[@intCast(y)] });
        } else {
            x -= 1;
            try edits_rev.append(allocator, .{ .op = .delete, .line = old[@intCast(x)] });
        }
    }

    // Remaining equals at the very start of both sequences.
    while (x > 0) {
        x -= 1;
        y -= 1;
        try edits_rev.append(allocator, .{ .op = .equal, .line = old[@intCast(x)] });
    }

    const edits = try edits_rev.toOwnedSlice(allocator);
    std.mem.reverse(Edit, edits);
    return edits;
}

// ── Tests ──────────────────────────────────────────────────────────────────

fn expectEdits(
    expected: []const Edit,
    actual: []const Edit,
) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try std.testing.expectEqual(e.op, a.op);
        try std.testing.expectEqualStrings(e.line, a.line);
    }
}

test "diff: identical sequences" {
    const gpa = std.testing.allocator;
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "a", "b", "c" };
    const edits = try diff(gpa, &old, &new);
    defer gpa.free(edits);
    const expected = [_]Edit{
        .{ .op = .equal, .line = "a" },
        .{ .op = .equal, .line = "b" },
        .{ .op = .equal, .line = "c" },
    };
    try expectEdits(&expected, edits);
}

test "diff: empty old" {
    const gpa = std.testing.allocator;
    const old = [_][]const u8{};
    const new = [_][]const u8{ "x", "y" };
    const edits = try diff(gpa, &old, &new);
    defer gpa.free(edits);
    const expected = [_]Edit{
        .{ .op = .insert, .line = "x" },
        .{ .op = .insert, .line = "y" },
    };
    try expectEdits(&expected, edits);
}

test "diff: empty new" {
    const gpa = std.testing.allocator;
    const old = [_][]const u8{ "a", "b" };
    const new = [_][]const u8{};
    const edits = try diff(gpa, &old, &new);
    defer gpa.free(edits);
    const expected = [_]Edit{
        .{ .op = .delete, .line = "a" },
        .{ .op = .delete, .line = "b" },
    };
    try expectEdits(&expected, edits);
}

test "diff: delete middle, insert end" {
    const gpa = std.testing.allocator;
    const old = [_][]const u8{ "a", "b", "c" };
    const new = [_][]const u8{ "a", "c", "d" };
    const edits = try diff(gpa, &old, &new);
    defer gpa.free(edits);
    const expected = [_]Edit{
        .{ .op = .equal, .line = "a" },
        .{ .op = .delete, .line = "b" },
        .{ .op = .equal, .line = "c" },
        .{ .op = .insert, .line = "d" },
    };
    try expectEdits(&expected, edits);
}

test "diff: completely different" {
    const gpa = std.testing.allocator;
    const old = [_][]const u8{ "x", "y" };
    const new = [_][]const u8{ "a", "b", "c" };
    const edits = try diff(gpa, &old, &new);
    defer gpa.free(edits);
    // Two deletes, three inserts; exact order depends on Myers choice.
    var del_count: usize = 0;
    var ins_count: usize = 0;
    for (edits) |e| switch (e.op) {
        .delete => del_count += 1,
        .insert => ins_count += 1,
        .equal => unreachable,
    };
    try std.testing.expectEqual(@as(usize, 2), del_count);
    try std.testing.expectEqual(@as(usize, 3), ins_count);
}

test "diff: edit lines borrow the input slices" {
    const gpa = std.testing.allocator;
    const old = [_][]const u8{ "alpha", "beta" };
    const new = [_][]const u8{ "alpha", "gamma" };
    const edits = try diff(gpa, &old, &new);
    defer gpa.free(edits);

    try std.testing.expectEqual(@intFromPtr(old[0].ptr), @intFromPtr(edits[0].line.ptr));
    try std.testing.expectEqual(@intFromPtr(old[1].ptr), @intFromPtr(edits[1].line.ptr));
    try std.testing.expectEqual(@intFromPtr(new[1].ptr), @intFromPtr(edits[2].line.ptr));
}

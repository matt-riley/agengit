const std = @import("std");
const test_support = @import("test_support");
const store_mod = test_support.store;

const lookups_per_scenario: usize = 10_000;

test "bench resolve prefix" {
    if (envFlagEnabled("AGIT_SKIP_RESOLVE_PREFIX_BENCH")) return;
    const scenarios = [_]usize{ 100, 10_000, 1_000_000 };
    for (scenarios) |object_count| {
        try runScenario(object_count);
    }
}

fn runScenario(object_count: usize) !void {
    const gpa = std.heap.page_allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try store_mod.Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    var hashes: std.ArrayList(store_mod.Hash) = .empty;
    defer hashes.deinit(gpa);
    try hashes.ensureTotalCapacity(gpa, object_count);

    for (0..object_count) |i| {
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "bench-object-{d}", .{i});
        const h = try store.writeBlob(io, content);
        hashes.appendAssumeCapacity(h);
    }

    var prng = std.Random.DefaultPrng.init(0xdecafbadcafefeed);
    const random = prng.random();

    const start = std.Io.Timestamp.now(io, .awake);
    for (0..lookups_per_scenario) |_| {
        const target = hashes.items[random.uintLessThan(usize, hashes.items.len)];
        const hex = target.toHex();
        const resolution = try store.resolvePrefix(io, gpa, hex[0..12]);
        switch (resolution) {
            .unique => |resolved| {
                if (!resolved.eql(target)) return error.ResolvePrefixMismatch;
            },
            else => return error.ResolvePrefixUnexpectedResult,
        }
    }
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
    const total_us = elapsed.toMicroseconds();
    const per_lookup_us = @divTrunc(total_us, @as(i64, lookups_per_scenario));
    std.debug.print(
        "bench-resolve-prefix: objects={d} lookups={d} total_us={d} per_lookup_us={d}\n",
        .{ object_count, lookups_per_scenario, total_us, per_lookup_us },
    );
}

fn envFlagEnabled(name: []const u8) bool {
    const result = std.process.run(std.heap.page_allocator, std.testing.io, .{
        .argv = &.{ "/usr/bin/printenv", name },
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return false;
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n");
    return std.mem.eql(u8, trimmed, "1");
}

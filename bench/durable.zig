const std = @import("std");
const fs_mod = @import("fs_util");

test "bench durable atomic replace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.createDirPath(io, "bench");
    var bench_dir = try tmp.dir.openDir(io, "bench", .{});
    defer bench_dir.close(io);

    const iterations: usize = 1000;
    const start = std.Io.Timestamp.now(io, .awake);
    for (0..iterations) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file-{d}.txt", .{i % 16});
        var af = try bench_dir.createFileAtomic(io, name, .{ .replace = true, .make_path = false });
        defer af.deinit(io);
        try af.file.writeStreamingAll(io, "durable-write");
        try fs_mod.atomicReplace(io, &af);
    }
    const elapsed = start.durationTo(std.Io.Timestamp.now(io, .awake));
    const total_us: i64 = elapsed.toMicroseconds();
    const per_op_us: i64 = @divTrunc(total_us, @as(i64, iterations));
    std.debug.print(
        "bench-durable: iterations={d} total_us={d} per_op_us={d}\n",
        .{ iterations, total_us, per_op_us },
    );
}

const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");

// Phase 6 implementation: print a raw CAS object by its BLAKE3 hash.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const prefix = iter.next() orelse {
        try stdout.interface.writeAll("usage: agit cat <hash>\n");
        try stdout.flush();
        return;
    };

    var store = (try status.openStoreOrDie(io, gpa, &stdout)) orelse return;
    defer store.deinit(io);

    const h = store.resolvePrefix(io, gpa, prefix) catch |err| {
        switch (err) {
            error.ObjectNotFound => try stdout.interface.print(
                "error: object '{s}' not found\n",
                .{prefix},
            ),
            error.AmbiguousPrefix => try stdout.interface.print(
                "error: ambiguous prefix '{s}' — be more specific\n",
                .{prefix},
            ),
            else => try stdout.interface.print("error: {s}\n", .{@errorName(err)}),
        }
        try stdout.flush();
        return;
    };

    const data = try store.readBlob(io, gpa, h);
    defer gpa.free(data);

    try stdout.interface.writeAll(data);
    try stdout.flush();
}

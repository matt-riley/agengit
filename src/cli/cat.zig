const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");

pub const usage = help_mod.UsageSpec{
    .name = "cat",
    .synopsis = "[OPTIONS] <HASH>",
    .description = "Print a raw object by its BLAKE3 hash.",
    .options = &.{
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "print object content", .command = "abc123def" },
    },
};

// Phase 6 implementation: print a raw CAS object by its BLAKE3 hash.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    // Parse --help and hash prefix
    var help_requested = false;
    var hash_prefix: ?[:0]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help_requested = true;
            break;
        } else if (hash_prefix == null) {
            hash_prefix = arg;
        }
    }

    if (help_requested) {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    }

    const prefix = hash_prefix orelse {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    };

    var store = try status.openStoreOrExit(io, gpa, &stdout, .human, usage.name);
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

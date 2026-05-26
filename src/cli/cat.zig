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

    const resolution = store.resolvePrefix(io, gpa, prefix) catch |err| {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
            .code = "object_lookup_failed",
            .message = "Failed to resolve object prefix.",
            .hint = @errorName(err),
            .hash = prefix,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    const h = switch (resolution) {
        .not_found => {
            try status.writeDiagnostic(&stdout, .human, usage.name, .{
                .code = "object_not_found",
                .message = "Object not found.",
                .hint = "Use a longer or different hash prefix.",
                .hash = prefix,
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .ambiguous => |matches| {
            var candidate_hex: [2][64]u8 = .{ matches[0].toHex(), matches[1].toHex() };
            if (std.mem.lessThan(u8, candidate_hex[1][0..], candidate_hex[0][0..])) {
                std.mem.swap([64]u8, &candidate_hex[0], &candidate_hex[1]);
            }
            const candidates = [_][]const u8{ candidate_hex[0][0..], candidate_hex[1][0..] };
            try status.writeDiagnostic(&stdout, .human, usage.name, .{
                .code = "ambiguous_hash_prefix",
                .message = "Hash prefix is ambiguous.",
                .hint = "Use a longer hash prefix.",
                .hash = prefix,
                .candidates = candidates[0..],
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .unique => |resolved| resolved,
    };

    const data = try store.readBlob(io, gpa, h);
    defer gpa.free(data);

    try stdout.interface.writeAll(data);
    try stdout.flush();
}

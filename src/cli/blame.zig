const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");

pub const usage = help_mod.UsageSpec{
    .name = "blame",
    .synopsis = "[OPTIONS] <FILE>",
    .description = "Show per-line step attribution for a file path.",
    .options = &.{
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show blame for a file", .command = "src/main.zig" },
    },
    .notes = "Blame recording is not yet available. Blame maps will be written in a future version.",
};

// Phase 6 implementation: show per-line step attribution for a file path.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = gpa;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    // Parse --help and file path
    var help_requested = false;
    var file_path: ?[:0]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help_requested = true;
            break;
        } else if (file_path == null) {
            file_path = arg;
        }
    }

    if (help_requested) {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    }

    // Blame recording is not yet implemented in the capture engine.
    // Blame maps will be written in a future phase when the recorder
    // calls store.writeBlame() during recordAssistantAndFinalize.
    try stdout.interface.writeAll("agit blame: blame recording is not yet available.\n");
    try stdout.interface.writeAll("Run `agit reindex` after upgrading to a version with blame support.\n");
    try stdout.flush();
}

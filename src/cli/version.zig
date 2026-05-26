const std = @import("std");
const help_mod = @import("help.zig");
const specs = @import("specs.zig");
const version_mod = @import("../version.zig");

pub const usage = specs.version_usage;

pub fn run(io: std.Io, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(&stdout, usage);
            try stdout.flush();
            return;
        }

        try stdout.interface.print("error: unknown option '{s}'\n\n", .{arg});
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        std.process.exit(1);
    }

    try stdout.interface.print("agit {s}\n", .{version_mod.value});
    try stdout.flush();
}

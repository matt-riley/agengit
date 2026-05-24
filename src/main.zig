const std = @import("std");

pub const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iter.deinit();

    _ = args_iter.next(); // skip argv[0] (program name)

    const cmd = args_iter.next() orelse {
        try printUsage(&stdout);
        try stdout.flush();
        std.process.exit(1);
    };

    if (std.mem.eql(u8, cmd, "version") or
        std.mem.eql(u8, cmd, "--version") or
        std.mem.eql(u8, cmd, "-V"))
    {
        try stdout.interface.print("agit {s}\n", .{version});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h") or
        std.mem.eql(u8, cmd, "help"))
    {
        try printUsage(&stdout);
        try stdout.flush();
        return;
    }

    try stderr.interface.print("error: unknown command '{s}'\n\nRun 'agit --help' for usage.\n", .{cmd});
    try stderr.flush();
    std.process.exit(1);
}

fn printUsage(w: *std.Io.File.Writer) !void {
    try w.interface.writeAll(
        \\agit - AI agent version control
        \\
        \\Usage: agit <command> [options]
        \\
        \\Commands:
        \\  init          Set up agit in the current repository
        \\  uninstall     Remove agit hooks from agent configurations
        \\  doctor        Check agent hook configurations and store health
        \\  status        Show current repository state
        \\  sessions      List recorded agent sessions
        \\  log           Show step history for a session
        \\  show          Show details of a step
        \\  blame         Show per-line step attribution for a file
        \\  cat           Print a raw object by hash
        \\  version       Print version information
        \\  completion    Generate shell completion scripts
        \\
        \\Run 'agit <command> --help' for command-specific help.
        \\
    );
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "version starts with a digit" {
    try std.testing.expect(version[0] >= '0' and version[0] <= '9');
}

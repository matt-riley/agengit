const std = @import("std");
const clap = @import("clap");

const cli = struct {
    const init_cmd = @import("cli/init.zig");
    const uninstall = @import("cli/uninstall.zig");
    const doctor = @import("cli/doctor.zig");
    const status = @import("cli/status.zig");
    const sessions = @import("cli/sessions.zig");
    const log_cmd = @import("cli/log.zig");
    const show = @import("cli/show.zig");
    const blame = @import("cli/blame.zig");
    const cat = @import("cli/cat.zig");
    const completion = @import("cli/completion.zig");
};

pub const version = "0.1.0";

const SubCommand = enum {
    init,
    uninstall,
    doctor,
    status,
    sessions,
    log,
    show,
    blame,
    cat,
    version,
    completion,
    help,
};

const top_parsers = .{
    .command = clap.parsers.enumeration(SubCommand),
};

const top_params = clap.parseParamsComptime(
    \\-h, --help     Display this help and exit.
    \\-V, --version  Print version and exit.
    \\<command>
    \\
);

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();

    _ = iter.next(); // skip argv[0]

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &top_params, top_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        try stderr.flush();
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.version != 0) {
        try stdout.interface.print("agit {s}\n", .{version});
        try stdout.flush();
        return;
    }

    if (res.args.help != 0 or res.positionals[0] == null) {
        try printUsage(&stdout);
        try stdout.flush();
        if (res.positionals[0] == null and res.args.help == 0) {
            std.process.exit(1);
        }
        return;
    }

    const cmd = res.positionals[0].?;

    switch (cmd) {
        .version => {
            try stdout.interface.print("agit {s}\n", .{version});
            try stdout.flush();
        },
        .help => {
            try printUsage(&stdout);
            try stdout.flush();
        },
        .init => try cli.init_cmd.run(init.io, init.gpa, &iter),
        .uninstall => try cli.uninstall.run(init.io, init.gpa, &iter),
        .doctor => try cli.doctor.run(init.io, init.gpa, &iter),
        .status => try cli.status.run(init.io, init.gpa, &iter),
        .sessions => try cli.sessions.run(init.io, init.gpa, &iter),
        .log => try cli.log_cmd.run(init.io, init.gpa, &iter),
        .show => try cli.show.run(init.io, init.gpa, &iter),
        .blame => try cli.blame.run(init.io, init.gpa, &iter),
        .cat => try cli.cat.run(init.io, init.gpa, &iter),
        .completion => try cli.completion.run(init.io, init.gpa, &iter),
    }

    try stdout.flush();
}

fn printUsage(w: *std.Io.File.Writer) !void {
    try w.interface.writeAll(
        \\agit - AI agent version control
        \\
        \\Usage: agit [options] <command> [command-options]
        \\
        \\Options:
        \\  -h, --help     Display this help and exit.
        \\  -V, --version  Print version and exit.
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

// Pull util module tests into the main test binary.
test {
    _ = @import("util/file_lock.zig");
    _ = @import("util/exe_path.zig");
}

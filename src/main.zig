const std = @import("std");
const clap = @import("clap");
const fs_mod = @import("util/fs.zig");
const file_limits_mod = @import("util/file_limits.zig");
const file_lock_mod = @import("util/file_lock.zig");
const hook_mod = @import("hook.zig");
const registry = @import("cli/registry.zig");
const version_mod = @import("version.zig");

const cli = struct {
    const help = @import("cli/help.zig");
    const init_cmd = @import("cli/init.zig");
    const uninstall = @import("cli/uninstall.zig");
    const doctor = @import("cli/doctor.zig");
    const fsck = @import("cli/fsck.zig");
    const gc = @import("cli/gc.zig");
    const push = @import("cli/push.zig");
    const pull = @import("cli/pull.zig");
    const status = @import("cli/status.zig");
    const timeline = @import("cli/timeline.zig");
    const sessions = @import("cli/sessions.zig");
    const log_cmd = @import("cli/log.zig");
    const show = @import("cli/show.zig");
    const diff = @import("cli/diff.zig");
    const grep = @import("cli/grep.zig");
    const blame = @import("cli/blame.zig");
    const cat = @import("cli/cat.zig");
    const privacy = @import("cli/privacy.zig");
    const completion = @import("cli/completion.zig");
    const reindex = @import("cli/reindex.zig");
    const version = @import("cli/version.zig");
    const claude_hook = @import("cli/claude_hook.zig");
    const claude_tool_batch_hook = @import("cli/claude_tool_batch_hook.zig");
    const codex_hook = @import("cli/codex_hook.zig");
    const gemini_hook = @import("cli/gemini_hook.zig");
};

pub const version = version_mod.value;

const SubCommand = enum {
    init,
    uninstall,
    doctor,
    fsck,
    gc,
    push,
    pull,
    status,
    timeline,
    sessions,
    log,
    show,
    diff,
    grep,
    blame,
    cat,
    privacy,
    reindex,
    version,
    completion,
    help,
    @"claude-hook",
    @"claude-tool-batch-hook",
    @"codex-hook",
    @"gemini-hook",
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
    fs_mod.configureFromEnviron(init.minimal.environ);
    file_limits_mod.configureFromEnviron(init.minimal.environ);
    file_lock_mod.configureFromEnviron(init.minimal.environ);
    hook_mod.configureFromEnviron(init.minimal.environ);

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
            try cli.version.run(init.io, &iter);
        },
        .help => {
            try printUsage(&stdout);
            try stdout.flush();
        },
        .init => try cli.init_cmd.run(init.io, init.gpa, init.minimal.environ, &iter),
        .uninstall => try cli.uninstall.run(init.io, init.gpa, init.minimal.environ, &iter),
        .doctor => try cli.doctor.run(init.io, init.gpa, init.minimal.environ, &iter),
        .fsck => try cli.fsck.run(init.io, init.gpa, &iter),
        .gc => try cli.gc.run(init.io, init.gpa, &iter),
        .push => try cli.push.run(init.io, init.gpa, init.minimal.environ, &iter),
        .pull => try cli.pull.run(init.io, init.gpa, init.minimal.environ, &iter),
        .status => try cli.status.run(init.io, init.gpa, init.minimal.environ, &iter),
        .timeline => try cli.timeline.run(init.io, init.gpa, &iter),
        .sessions => try cli.sessions.run(init.io, init.gpa, &iter),
        .log => try cli.log_cmd.run(init.io, init.gpa, &iter),
        .show => try cli.show.run(init.io, init.gpa, &iter),
        .diff => try cli.diff.run(init.io, init.gpa, &iter),
        .grep => try cli.grep.run(init.io, init.gpa, &iter),
        .blame => try cli.blame.run(init.io, init.gpa, &iter),
        .cat => try cli.cat.run(init.io, init.gpa, &iter),
        .privacy => try cli.privacy.run(init.io, init.gpa, &iter),
        .reindex => try cli.reindex.run(init.io, init.gpa, &iter),
        .completion => try cli.completion.run(init.io, init.gpa, &iter),
        .@"claude-hook" => try cli.claude_hook.run(init.io, init.gpa, &iter),
        .@"claude-tool-batch-hook" => try cli.claude_tool_batch_hook.run(init.io, init.gpa, &iter),
        .@"codex-hook" => try cli.codex_hook.run(init.io, init.gpa, &iter),
        .@"gemini-hook" => try cli.gemini_hook.run(init.io, init.gpa, &iter),
    }

    try stdout.flush();
}

fn printUsage(w: *std.Io.File.Writer) !void {
    try cli.help.renderTopLevelUsage(w, &registry.public_commands);
}

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "version starts with a digit" {
    try std.testing.expect(version[0] >= '0' and version[0] <= '9');
}

// Pull util module tests into the main test binary.
test {
    _ = @import("util/buf_pool.zig");
    _ = @import("util/file_lock.zig");
    _ = @import("util/file_limits.zig");
    _ = @import("util/fs.zig");
    _ = @import("util/date.zig");
    _ = @import("util/exe_path.zig");
    _ = @import("util/home.zig");
    _ = @import("store/store.zig");
    _ = @import("store/ignore.zig");
    _ = @import("store/diff.zig");
    _ = @import("store/inspect.zig");
    _ = @import("store/blame.zig");
    _ = @import("store/snapshot.zig");
    _ = @import("store/config.zig");
    _ = @import("store/pack.zig");
    _ = @import("recorder.zig");
    _ = @import("hook.zig");
    _ = @import("hook/Adapter.zig");
    _ = @import("hook/payload.zig");
    _ = @import("hook/runner.zig");
    _ = @import("hook/adapters/registry.zig");
    _ = @import("cli/help.zig");
    _ = @import("cli/specs.zig");
    _ = @import("cli/docgen.zig");
    _ = @import("cli/output.zig");
    _ = @import("cli/registry.zig");
    _ = @import("cli/claude_hook.zig");
    _ = @import("cli/claude_tool_batch_hook.zig");
    _ = @import("cli/codex_hook.zig");
    _ = @import("cli/gemini_hook.zig");
    _ = @import("cli/reindex.zig");
    _ = @import("cli/init.zig");
    _ = @import("cli/uninstall.zig");
    _ = @import("cli/doctor.zig");
    _ = @import("cli/fsck.zig");
    _ = @import("cli/gc.zig");
    _ = @import("cli/push.zig");
    _ = @import("cli/pull.zig");
    _ = @import("cli/status.zig");
    _ = @import("cli/timeline.zig");
    _ = @import("cli/sessions.zig");
    _ = @import("cli/log.zig");
    _ = @import("cli/show.zig");
    _ = @import("cli/diff.zig");
    _ = @import("cli/grep.zig");
    _ = @import("cli/blame.zig");
    _ = @import("cli/cat.zig");
    _ = @import("cli/privacy.zig");
    _ = @import("cli/version.zig");
    _ = @import("store/integrity.zig");
    _ = @import("store/gc.zig");
    _ = @import("store/remote.zig");
    _ = @import("privacy/redact.zig");
    _ = @import("privacy/scan.zig");
}

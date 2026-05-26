const std = @import("std");
const help_mod = @import("help.zig");

pub const init_usage = help_mod.UsageSpec{
    .name = "init",
    .synopsis = "[OPTIONS]",
    .description = "Set up agit hooks for installed agent CLIs.",
    .options = &.{
        .{ .long = "agent", .value_name = "name", .description = "Install only the specified agent (claude, codex, gemini). Can be repeated.", .repeatable = true, .value_choices = &.{ "claude", "codex", "gemini" } },
        .{ .long = "dry-run", .description = "Show what would be installed without making changes." },
        .{ .long = "force", .description = "Back up and replace malformed/non-object existing JSON config." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "install hooks for available agents", .command = "" },
        .{ .description = "preview installation without writing", .command = "--dry-run" },
        .{ .description = "install only Codex hooks", .command = "--agent codex" },
        .{ .description = "reinstall even if config exists", .command = "--force" },
    },
};

pub const uninstall_usage = help_mod.UsageSpec{
    .name = "uninstall",
    .synopsis = "[OPTIONS]",
    .description = "Remove agit hooks from agent configurations.",
    .options = &.{
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "remove all hooks", .command = "" },
    },
};

pub const doctor_usage = help_mod.UsageSpec{
    .name = "doctor",
    .synopsis = "[OPTIONS]",
    .description = "Check store health and agent hook configuration.",
    .options = &.{
        .{ .long = "json", .description = "Render doctor checks as structured JSON." },
        .{ .long = "locks", .description = "List currently held lock files with age and executable path." },
        .{ .long = "stats", .description = "Print finalize retry/object-write counters." },
        .{ .long = "last-hook-error", .description = "Pretty-print the newest hook-error log entry." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "check store and agent health", .command = "" },
        .{ .description = "show lock files in use", .command = "--locks" },
        .{ .description = "show finalize statistics", .command = "--stats" },
    },
};

pub const fsck_usage = help_mod.UsageSpec{
    .name = "fsck",
    .synopsis = "[OPTIONS]",
    .description = "Verify object, ref, index, and mutable-area integrity.",
    .options = &.{
        .{ .long = "json", .description = "Render fsck checks as structured JSON." },
        .{ .long = "reindex", .description = "Explicitly rebuild only index.db after a successful read-only scan." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "run a read-only integrity scan", .command = "" },
        .{ .description = "emit machine-readable findings", .command = "--json" },
        .{ .description = "rebuild index.db after a clean scan", .command = "--reindex" },
    },
};

pub const gc_usage = help_mod.UsageSpec{
    .name = "gc",
    .synopsis = "[OPTIONS]",
    .description = "Prune unreachable store data and stale temporary files.",
    .options = &.{
        .{ .long = "json", .description = "Render gc results as structured JSON." },
        .{ .long = "grace-hours", .value_name = "N", .description = "Only prune unreachable objects/tmp files older than <N> hours. Defaults to 2." },
        .{ .long = "prune-before", .value_name = "YYYY-MM-DD", .description = "Delete session refs whose head-step timestamp is older than UTC midnight on the given date before sweeping." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "prune unreachable store data with the default grace period", .command = "" },
        .{ .description = "immediately prune stale data without the 2-hour grace window", .command = "--grace-hours 0" },
        .{ .description = "drop sessions older than a UTC date before sweeping", .command = "--prune-before 2026-01-01" },
    },
};

pub const status_usage = help_mod.UsageSpec{
    .name = "status",
    .synopsis = "[OPTIONS]",
    .description = "Show current repository state and agit store statistics.",
    .options = &.{
        .{ .long = "json", .description = "Render the status as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show repository status", .command = "" },
    },
};

pub const sessions_usage = help_mod.UsageSpec{
    .name = "sessions",
    .synopsis = "[OPTIONS]",
    .description = "List recorded agent sessions from the index.",
    .options = &.{
        .{ .long = "json", .description = "Render the session list as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "list all sessions", .command = "" },
    },
};

pub const log_usage = help_mod.UsageSpec{
    .name = "log",
    .synopsis = "[OPTIONS] [SESSION_ID]",
    .description = "Show step history for a session.",
    .options = &.{
        .{ .long = "json", .description = "Render the session log as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show most recent session steps", .command = "" },
        .{ .description = "show steps for a specific session", .command = "session-abc123" },
    },
};

pub const show_usage = help_mod.UsageSpec{
    .name = "show",
    .synopsis = "[OPTIONS] <HASH>",
    .description = "Show details of a recorded step object by its BLAKE3 hash.",
    .options = &.{
        .{ .long = "json", .description = "Render the step details as structured JSON." },
        .{ .long = "redacted", .description = "Redact obvious secrets in the rendered output." },
        .{ .long = "full", .description = "Render full output even when redaction is the repo default." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show details of a step", .command = "abc123def" },
    },
};

pub const blame_usage = help_mod.UsageSpec{
    .name = "blame",
    .synopsis = "[OPTIONS] <FILE>",
    .description = "Show per-line step attribution for a file path.",
    .options = &.{
        .{ .long = "no-limits", .description = "Disable the blame file-size cap for this invocation when blame output is available." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show blame for a file", .command = "src/main.zig" },
    },
    .notes = "Blame recording is not yet available. When blame rendering lands, AGIT_MAX_FILE_BYTES will set the default large-file cap and --no-limits will disable it for one run.",
};

pub const cat_usage = help_mod.UsageSpec{
    .name = "cat",
    .synopsis = "[OPTIONS] <HASH>",
    .description = "Print a raw object by its BLAKE3 hash.",
    .options = &.{
        .{ .long = "redacted", .description = "Redact obvious secrets in the rendered object output." },
        .{ .long = "full", .description = "Render full object output even when redaction is the repo default." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "print object content", .command = "abc123def" },
    },
};

pub const privacy_usage = help_mod.UsageSpec{
    .name = "privacy",
    .synopsis = "scan [OPTIONS]",
    .description = "Scan reachable captured content for sensitive data without printing secret values.",
    .options = &.{
        .{ .long = "json", .description = "Render privacy scan findings as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "scan captured content for sensitive data", .command = "scan" },
        .{ .description = "emit machine-readable privacy findings", .command = "scan --json" },
    },
};

pub const reindex_usage = help_mod.UsageSpec{
    .name = "reindex",
    .synopsis = "[OPTIONS]",
    .description = "Rebuild the SQLite index from object/ref truth.",
    .options = &.{
        .{ .long = "from", .value_name = "HASH", .description = "Incrementally replay steps newer than <HASH> that are reachable from session refs." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "rebuild entire index", .command = "" },
        .{ .description = "incrementally update from a hash", .command = "--from abc123def" },
    },
};

pub const version_usage = help_mod.UsageSpec{
    .name = "version",
    .synopsis = "[OPTIONS]",
    .description = "Print agit version information.",
    .options = &.{
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "print the current version", .command = "" },
    },
};

pub const completion_usage = help_mod.UsageSpec{
    .name = "completion",
    .synopsis = "[OPTIONS] <SHELL>",
    .description = "Generate shell completion scripts for bash, zsh, fish, or nushell.",
    .options = &.{
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "bash completion script", .command = "bash" },
        .{ .description = "zsh completion script", .command = "zsh" },
        .{ .description = "fish completion script", .command = "fish" },
        .{ .description = "nushell completion script", .command = "nushell" },
    },
};

pub const public_commands = [_]help_mod.CommandSpec{
    .{ .name = "init", .summary = "Set up agit in the current repository", .usage = &init_usage },
    .{ .name = "uninstall", .summary = "Remove agit hooks from agent configurations", .usage = &uninstall_usage },
    .{ .name = "doctor", .summary = "Check agent hook configurations and store health", .usage = &doctor_usage },
    .{ .name = "fsck", .summary = "Verify store integrity without mutating data", .usage = &fsck_usage },
    .{ .name = "gc", .summary = "Prune unreachable store data and stale temporaries", .usage = &gc_usage },
    .{ .name = "status", .summary = "Show current repository state", .usage = &status_usage },
    .{ .name = "sessions", .summary = "List recorded agent sessions", .usage = &sessions_usage },
    .{ .name = "log", .summary = "Show step history for a session", .usage = &log_usage },
    .{ .name = "show", .summary = "Show details of a step", .usage = &show_usage },
    .{ .name = "blame", .summary = "Show per-line step attribution for a file", .usage = &blame_usage },
    .{ .name = "cat", .summary = "Print a raw object by hash", .usage = &cat_usage },
    .{ .name = "privacy", .summary = "Scan reachable content for sensitive data", .usage = &privacy_usage },
    .{ .name = "reindex", .summary = "Rebuild the index from the object store", .usage = &reindex_usage },
    .{ .name = "version", .summary = "Print version information", .usage = &version_usage },
    .{ .name = "completion", .summary = "Generate shell completion scripts", .usage = &completion_usage },
};

pub fn usageFor(name: []const u8) ?*const help_mod.UsageSpec {
    for (public_commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command.usage;
    }
    return null;
}

test "public command metadata stays internally consistent" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();

    for (public_commands) |command| {
        const usage = command.usage orelse unreachable;
        try std.testing.expect(command.name.len > 0);
        try std.testing.expect(command.summary.len > 0);
        try std.testing.expectEqualStrings(command.name, usage.name);
        try std.testing.expect(usage.examples.len > 0);
        try std.testing.expect(!seen.contains(command.name));
        try seen.put(command.name, {});
    }
}

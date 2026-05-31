const std = @import("std");
const help_mod = @import("help.zig");

pub const init_usage = help_mod.UsageSpec{
    .name = "init",
    .synopsis = "[OPTIONS]",
    .description = "Set up agit hooks for installed agent CLIs.",
    .options = &.{
        .{ .long = "agent", .value_name = "name", .description = "Install only the specified agent (claude, codex, gemini, copilot). Can be repeated.", .repeatable = true, .value_choices = &.{ "claude", "codex", "gemini", "copilot" } },
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

pub const observe_usage = help_mod.UsageSpec{
    .name = "observe",
    .synopsis = "[OPTIONS] <SOURCE>",
    .description = "Run an experimental observer source and record newly seen events.",
    .options = &.{
        .{ .long = "json", .description = "Render observe results as structured JSON." },
        .{ .long = "once", .description = "Process one batch of available events and exit." },
        .{ .long = "input", .value_name = "PATH", .description = "Source-specific input path (required for the fixture source)." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "process a fixture-backed observer file once", .command = "--once fixture --input observer.json" },
        .{ .description = "emit machine-readable observe stats", .command = "--json --once fixture --input observer.json" },
    },
    .notes = "Observer sources are explicit and experimental. Current sources run one pass and persist watermarks under .agit/observers/ for duplicate suppression on rerun.",
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

pub const push_usage = help_mod.UsageSpec{
    .name = "push",
    .synopsis = "[OPTIONS]",
    .description = "Upload reachable objects and session refs to a configured remote.",
    .options = &.{
        .{ .long = "json", .description = "Render push results as structured JSON." },
        .{ .long = "remote", .value_name = "name", .description = "Choose a configured remote by name." },
        .{ .long = "allow-sensitive", .description = "Allow plaintext uploads even when privacy scan findings exist." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "push to the only configured remote", .command = "" },
        .{ .description = "push to a named remote", .command = "--remote backup" },
        .{ .description = "emit machine-readable push stats", .command = "--json" },
    },
};

pub const pull_usage = help_mod.UsageSpec{
    .name = "pull",
    .synopsis = "[OPTIONS]",
    .description = "Download missing objects and refs from a configured remote.",
    .options = &.{
        .{ .long = "json", .description = "Render pull results as structured JSON." },
        .{ .long = "remote", .value_name = "name", .description = "Choose a configured remote by name." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "pull from the only configured remote", .command = "" },
        .{ .description = "pull from a named remote", .command = "--remote backup" },
        .{ .description = "emit machine-readable pull stats", .command = "--json" },
    },
};

pub const export_usage = help_mod.UsageSpec{
    .name = "export",
    .synopsis = "[OPTIONS] <PATH>",
    .description = "Write a portable bundle containing selected session refs and reachable objects.",
    .options = &.{
        .{ .long = "json", .description = "Render export results as structured JSON." },
        .{ .long = "origin", .value_name = "name", .description = "Only export sessions recorded by the given origin." },
        .{ .long = "session", .value_name = "origin/session-id", .description = "Only export one disambiguated session id." },
        .{ .long = "since", .value_name = "YYYY-MM-DD", .description = "Only select sessions with at least one step on or after UTC midnight for the given date." },
        .{ .long = "until", .value_name = "YYYY-MM-DD", .description = "Only select sessions with at least one step before UTC midnight after the given date." },
        .{ .long = "allow-sensitive", .description = "Allow plaintext export when privacy scan findings exist; writes a privacy report." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "export all recorded sessions into a bundle directory", .command = "dist/bundle" },
        .{ .description = "export one session", .command = "--session claude/session-123 dist/bundle" },
        .{ .description = "export a date-windowed bundle", .command = "--since 2026-05-01 --until 2026-05-31 dist/bundle" },
    },
};

pub const import_usage = help_mod.UsageSpec{
    .name = "import",
    .synopsis = "[OPTIONS] <PATH>",
    .description = "Import a portable bundle after validating hashes and ref conflicts.",
    .options = &.{
        .{ .long = "json", .description = "Render import results as structured JSON." },
        .{ .long = "replace-ref", .value_name = "origin/session-id", .description = "Overwrite a named canonical session ref instead of namespacing conflicts. Can be repeated." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "import a bundle directory", .command = "dist/bundle" },
        .{ .description = "replace one conflicting ref during import", .command = "--replace-ref claude/session-123 dist/bundle" },
    },
};

pub const status_usage = help_mod.UsageSpec{
    .name = "status",
    .synopsis = "[OPTIONS]",
    .description = "Show the current investigation dashboard for this repository.",
    .options = &.{
        .{ .long = "json", .description = "Render the status as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show repository status", .command = "" },
    },
};

pub const timeline_usage = help_mod.UsageSpec{
    .name = "timeline",
    .synopsis = "[OPTIONS]",
    .description = "Show recent recorded steps across sessions in reverse chronological order.",
    .options = &.{
        .{ .long = "origin", .value_name = "name", .description = "Only show steps recorded by the given origin." },
        .{ .long = "session", .value_name = "id", .description = "Only show one session id, or pass origin/session-id to disambiguate." },
        .{ .long = "since", .value_name = "YYYY-MM-DD", .description = "Only include steps on or after UTC midnight for the given date." },
        .{ .long = "until", .value_name = "YYYY-MM-DD", .description = "Only include steps before UTC midnight after the given date." },
        .{ .long = "limit", .value_name = "N", .description = "Show at most <N> steps. Defaults to 20." },
        .{ .long = "redacted", .description = "Redact obvious secrets in previews." },
        .{ .long = "full", .description = "Render full previews even when redaction is the repo default." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show the most recent recorded steps", .command = "" },
        .{ .description = "filter to one origin and date window", .command = "--origin codex --since 2026-05-01 --until 2026-05-31" },
        .{ .description = "show one session timeline", .command = "--session claude/session-abc123" },
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

pub const restore_usage = help_mod.UsageSpec{
    .name = "restore",
    .synopsis = "[OPTIONS] <HASH> [-- <PATH>...]",
    .description = "Restore captured files from a step snapshot into the working tree. Whole-tree restores require --all; existing files are skipped unless --force is set.",
    .options = &.{
        .{ .long = "json", .description = "Render the restore summary as structured JSON." },
        .{ .long = "all", .description = "Restore every file in the captured snapshot." },
        .{ .long = "force", .description = "Overwrite existing files instead of skipping them." },
        .{ .long = "dry-run", .description = "Report what would be restored without writing files." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "restore one captured file", .command = "abc123def -- src/main.zig" },
        .{ .description = "preview restoring an entire snapshot", .command = "--dry-run --all abc123def" },
        .{ .description = "overwrite an existing local file", .command = "--force abc123def -- README.md" },
    },
};

pub const show_usage = help_mod.UsageSpec{
    .name = "show",
    .synopsis = "[OPTIONS] <HASH>",
    .description = "Show details of a recorded step object by its BLAKE3 hash.",
    .options = &.{
        .{ .long = "json", .description = "Render the step details as structured JSON." },
        .{ .long = "files", .description = "List captured files from the step tree." },
        .{ .long = "stat", .description = "Summarize file changes between this step and its parent." },
        .{ .long = "redacted", .description = "Redact obvious secrets in the rendered output." },
        .{ .long = "full", .description = "Render full output even when redaction is the repo default." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show details of a step", .command = "abc123def" },
        .{ .description = "show captured files for a step", .command = "--files abc123def" },
        .{ .description = "show file-change counts for a step", .command = "--stat abc123def" },
    },
};

pub const diff_usage = help_mod.UsageSpec{
    .name = "diff",
    .synopsis = "[OPTIONS] (<HASH> [<HASH>] | --session <ID>) [-- <PATH>]",
    .description = "Render a diff for one step, between two steps, or across a session.",
    .options = &.{
        .{ .long = "json", .description = "Render diff metadata and changed paths as structured JSON." },
        .{ .long = "session", .value_name = "id", .description = "Diff the first step's parent tree against the latest step in one session." },
        .{ .long = "redacted", .description = "Redact obvious secrets in diff output." },
        .{ .long = "full", .description = "Render full diff output even when redaction is the repo default." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "diff a recorded step against its parent", .command = "abc123def" },
        .{ .description = "diff two recorded steps", .command = "abc123def fed456abc" },
        .{ .description = "diff a complete session", .command = "--session codex/session-abc123" },
        .{ .description = "diff one captured path only", .command = "abc123def -- src/main.zig" },
    },
};

pub const between_usage = help_mod.UsageSpec{
    .name = "between",
    .synopsis = "[OPTIONS] <FROM> [TO]",
    .description = "Show recorded steps whose captured Git commit falls between two revisions.",
    .options = &.{
        .{ .long = "json", .description = "Render matching steps as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show steps recorded after one commit through HEAD", .command = "abc123def" },
        .{ .description = "show steps recorded between two tags", .command = "v1.0.0 v1.1.0" },
    },
};

pub const grep_usage = help_mod.UsageSpec{
    .name = "grep",
    .synopsis = "[OPTIONS] <QUERY>",
    .description = "Search recorded messages and tool activity across all sessions.",
    .options = &.{
        .{ .long = "json", .description = "Render grep matches as structured JSON." },
        .{ .long = "origin", .value_name = "name", .description = "Only search matches recorded by the given origin." },
        .{ .long = "session", .value_name = "id", .description = "Only search one session id, or pass origin/session-id to disambiguate." },
        .{ .long = "since", .value_name = "YYYY-MM-DD", .description = "Only include matches on or after UTC midnight for the given date." },
        .{ .long = "until", .value_name = "YYYY-MM-DD", .description = "Only include matches before UTC midnight after the given date." },
        .{ .long = "limit", .value_name = "N", .description = "Return at most <N> matches. Defaults to 20." },
        .{ .long = "context", .value_name = "N", .description = "Use <N> snippet tokens around each match. Defaults to 12." },
        .{ .long = "redacted", .description = "Redact obvious secrets in rendered snippets." },
        .{ .long = "full", .description = "Render full snippets even when redaction is the repo default." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "search all recorded sessions for a term", .command = "factorial" },
        .{ .description = "filter matches to one origin and date range", .command = "--origin claude --since 2026-05-01 --until 2026-05-31 factorial" },
        .{ .description = "search a specific session", .command = "--session claude/session-abc123 token" },
    },
};

pub const blame_usage = help_mod.UsageSpec{
    .name = "blame",
    .synopsis = "[OPTIONS] <FILE>",
    .description = "Show per-line step attribution for a file path.",
    .options = &.{
        .{ .long = "json", .description = "Render blame attribution as structured JSON." },
        .{ .long = "step", .value_name = "hash", .description = "Show blame as of the given step instead of the latest." },
        .{ .long = "no-limits", .description = "Disable the blame file-size cap for this invocation." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show blame for a file", .command = "src/main.zig" },
        .{ .description = "show blame as of a specific step", .command = "--step abc123 src/main.zig" },
    },
    .notes = "AGIT_MAX_FILE_BYTES sets the default large-file cap and --no-limits disables it for one run.",
};

pub const watch_usage = help_mod.UsageSpec{
    .name = "watch",
    .synopsis = "[OPTIONS]",
    .description = "Follow newly recorded steps as they are finalized.",
    .options = &.{
        .{ .long = "json", .description = "Render each watch event as a cli-json-v1 JSON line." },
        .{ .long = "origin", .value_name = "name", .description = "Only follow steps recorded by the given origin." },
        .{ .long = "session", .value_name = "id", .description = "Only follow one session id, or pass origin/session-id to disambiguate." },
        .{ .long = "since", .value_name = "YYYY-MM-DD", .description = "Stream existing and new steps on or after UTC midnight for the given date." },
        .{ .long = "interval", .value_name = "DURATION", .description = "Polling interval such as 1s or 250ms. Defaults to 1s." },
        .{ .long = "redacted", .description = "Redact obvious secrets in rendered previews." },
        .{ .long = "full", .description = "Render full previews even when redaction is the repo default." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "follow newly recorded steps", .command = "" },
        .{ .description = "follow one Codex session with a faster poll interval", .command = "--session codex/session-abc123 --interval 250ms" },
        .{ .description = "stream JSON lines from today onward", .command = "--json --since 2026-05-31" },
    },
    .notes = "Watch polls the local SQLite index for committed steps and is near-real-time, not event-driven. Use `agit timeline` for one-shot CI output.",
};

pub const stats_usage = help_mod.UsageSpec{
    .name = "stats",
    .synopsis = "[OPTIONS]",
    .description = "Summarize recorded session, step, tool, and file-change activity.",
    .options = &.{
        .{ .long = "json", .description = "Render stats as structured JSON." },
        .{ .long = "session", .value_name = "id", .description = "Only summarize one session id, or pass origin/session-id to disambiguate." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show repository-wide analytics", .command = "" },
        .{ .description = "show analytics for one session", .command = "--session codex/session-abc123" },
        .{ .description = "emit machine-readable analytics", .command = "--json" },
    },
    .notes = "Stats read the SQLite index; run `agit reindex` if the index has drifted. Most-changed paths are computed from at most 500 steps by default.",
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
    .{ .name = "observe", .summary = "Run an experimental observer source", .usage = &observe_usage },
    .{ .name = "uninstall", .summary = "Remove agit hooks from agent configurations", .usage = &uninstall_usage },
    .{ .name = "doctor", .summary = "Check agent hook configurations and store health", .usage = &doctor_usage },
    .{ .name = "fsck", .summary = "Verify store integrity without mutating data", .usage = &fsck_usage },
    .{ .name = "gc", .summary = "Prune unreachable store data and stale temporaries", .usage = &gc_usage },
    .{ .name = "push", .summary = "Upload store history to a configured remote", .usage = &push_usage },
    .{ .name = "pull", .summary = "Download store history from a configured remote", .usage = &pull_usage },
    .{ .name = "export", .summary = "Write a portable bundle from selected sessions", .usage = &export_usage },
    .{ .name = "import", .summary = "Import a portable bundle into the local store", .usage = &import_usage },
    .{ .name = "status", .summary = "Show the investigation dashboard", .usage = &status_usage },
    .{ .name = "timeline", .summary = "Show recent recorded steps", .usage = &timeline_usage },
    .{ .name = "sessions", .summary = "List recorded agent sessions", .usage = &sessions_usage },
    .{ .name = "log", .summary = "Show step history for a session", .usage = &log_usage },
    .{ .name = "restore", .summary = "Restore files from a recorded snapshot", .usage = &restore_usage },
    .{ .name = "show", .summary = "Show details of a step", .usage = &show_usage },
    .{ .name = "diff", .summary = "Show captured file diffs", .usage = &diff_usage },
    .{ .name = "between", .summary = "Show steps recorded between Git revisions", .usage = &between_usage },
    .{ .name = "grep", .summary = "Search recorded messages and tool activity", .usage = &grep_usage },
    .{ .name = "blame", .summary = "Show per-line step attribution for a file", .usage = &blame_usage },
    .{ .name = "watch", .summary = "Follow newly recorded steps", .usage = &watch_usage },
    .{ .name = "stats", .summary = "Summarize recorded activity", .usage = &stats_usage },
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

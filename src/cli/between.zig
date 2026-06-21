const std = @import("std");
const git_mod = @import("../util/git.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const status = @import("status.zig");
const arg_parse = @import("arg_parse.zig");
const store_mod = @import("../store/store.zig");

pub const usage = specs.between_usage;

const Options = struct {
    format: output_mod.Format = .human,
    from: ?[:0]const u8 = null,
    to: ?[:0]const u8 = null,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    const from = options.from orelse {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "missing_revision",
            .message = "A starting revision is required.",
            .hint = "Use `agit between <from> [to]`.",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    const to = options.to orelse "HEAD";

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    const git_cwd = std.Io.Dir.cwd();
    const from_resolved = try git_mod.resolveRevision(io, gpa, git_cwd, from) orelse {
        try writeGitDiagnostic(&stdout, options.format, "from_revision_not_found", "Could not resolve the starting revision.", from);
        try stdout.flush();
        std.process.exit(1);
    };
    defer gpa.free(from_resolved);
    const to_resolved = try git_mod.resolveRevision(io, gpa, git_cwd, to) orelse {
        try writeGitDiagnostic(&stdout, options.format, "to_revision_not_found", "Could not resolve the ending revision.", to);
        try stdout.flush();
        std.process.exit(1);
    };
    defer gpa.free(to_resolved);

    const commits = try git_mod.listRangeCommits(io, gpa, git_cwd, from_resolved, to_resolved) orelse {
        try writeGitDiagnostic(&stdout, options.format, "range_lookup_failed", "Could not list commits in the requested range.", from);
        try stdout.flush();
        std.process.exit(1);
    };
    defer git_mod.freeCommitList(gpa, commits);

    var rows: std.ArrayList(store_mod.TimelineRow) = .empty;
    defer {
        for (rows.items) |row| store_mod.freeTimelineRow(gpa, row);
        rows.deinit(gpa);
    }

    {
        const from_rows = try store.index.listStepsByGitCommit(gpa, from_resolved);
        errdefer store_mod.freeTimelineRows(gpa, from_rows);
        try rows.appendSlice(gpa, from_rows);
        gpa.free(from_rows);
    }
    for (commits) |commit| {
        {
            const commit_rows = try store.index.listStepsByGitCommit(gpa, commit);
            errdefer store_mod.freeTimelineRows(gpa, commit_rows);
            try rows.appendSlice(gpa, commit_rows);
            gpa.free(commit_rows);
        }
    }
    std.mem.sort(store_mod.TimelineRow, rows.items, {}, lessBySessionThenTime);

    const missing_git_count = try store.index.countStepsWithoutGitCommit();

    switch (options.format) {
        .human => try writeHuman(&stdout, from, to, from_resolved, to_resolved, commits, rows.items, missing_git_count),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .from = from,
            .to = to,
            .from_commit = from_resolved,
            .to_commit = to_resolved,
            .range_commits = commits,
            .steps = rows.items,
            .steps_without_git_commit = missing_git_count,
        }),
    }
    try stdout.flush();
}

fn writeHuman(
    stdout: *std.Io.File.Writer,
    from: []const u8,
    to: []const u8,
    from_resolved: []const u8,
    to_resolved: []const u8,
    commits: []const []const u8,
    rows: []const store_mod.TimelineRow,
    missing_git_count: i64,
) !void {
    try stdout.interface.print("range {s}..{s}  {s}..{s}  {d} commit(s)\n", .{
        from,
        to,
        from_resolved[0..@min(12, from_resolved.len)],
        to_resolved[0..@min(12, to_resolved.len)],
        commits.len + 1,
    });

    if (rows.len == 0) {
        try stdout.interface.writeAll("No recorded steps match commits in this range.\n");
    } else {
        var ts_buf: [32]u8 = undefined;
        var current_origin: ?[]const u8 = null;
        var current_session: ?[]const u8 = null;
        for (rows) |row| {
            const same_session = current_origin != null and
                std.mem.eql(u8, current_origin.?, row.origin) and
                std.mem.eql(u8, current_session.?, row.session_id);
            if (!same_session) {
                current_origin = row.origin;
                current_session = row.session_id;
                try stdout.interface.print("\n{s}/{s}\n", .{ row.origin, row.session_id });
            }
            const git_commit = row.git_commit orelse "(unknown)";
            try stdout.interface.print("  {s}  turn {s}  step {s}  git {s}{s}\n", .{
                status.formatTimestamp(row.timestamp, &ts_buf),
                row.turn_id,
                row.hash[0..@min(12, row.hash.len)],
                git_commit[0..@min(12, git_commit.len)],
                if (row.git_dirty orelse false) "*" else "",
            });
        }
    }

    if (missing_git_count > 0) {
        try stdout.interface.print("\n{d} recorded step(s) have no git commit context and were not considered.\n", .{missing_git_count});
    }
}

fn writeGitDiagnostic(
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    code: []const u8,
    message: []const u8,
    revision: []const u8,
) !void {
    try status.writeDiagnostic(stdout, format, usage.name, .{
        .code = code,
        .message = message,
        .hint = "Ensure this is a Git repository and the revision exists.",
        .path = revision,
    });
}

fn lessBySessionThenTime(_: void, a: store_mod.TimelineRow, b: store_mod.TimelineRow) bool {
    const origin_order = std.mem.order(u8, a.origin, b.origin);
    if (origin_order != .eq) return origin_order == .lt;
    const session_order = std.mem.order(u8, a.session_id, b.session_id);
    if (session_order != .eq) return session_order == .lt;
    if (a.timestamp != b.timestamp) return a.timestamp < b.timestamp;
    return std.mem.lessThan(u8, a.hash, b.hash);
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !Options {
    var options: Options = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (options.from == null) {
            options.from = arg;
        } else if (options.to == null) {
            options.to = arg;
        } else {
            arg_parse.invalidArg(stdout, options.format, usage, "Unexpected argument.") catch {};
            std.process.exit(1);
        }
    }
    return options;
}

const std = @import("std");

const git_timeout: std.Io.Timeout = .{
    .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(5000),
        .clock = .awake,
    },
};

const small_output_limit = std.Io.Limit.limited(4096);

pub const Context = struct {
    commit: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    dirty: ?bool = null,

    pub fn deinit(self: *Context, gpa: std.mem.Allocator) void {
        if (self.commit) |value| gpa.free(value);
        if (self.branch) |value| gpa.free(value);
        self.* = undefined;
    }
};

pub fn captureContext(io: std.Io, gpa: std.mem.Allocator, repo_dir: std.Io.Dir) !Context {
    var context: Context = .{};
    errdefer context.deinit(gpa);

    context.commit = try runGitTrimmedAlloc(gpa, io, repo_dir, &.{
        "git",
        "rev-parse",
        "--verify",
        "HEAD",
    });
    if (context.commit == null) return context;

    context.branch = try runGitTrimmedAlloc(gpa, io, repo_dir, &.{
        "git",
        "branch",
        "--show-current",
    });
    if (context.branch) |branch| {
        if (branch.len == 0) {
            gpa.free(branch);
            context.branch = null;
        }
    }

    context.dirty = try runGitDirty(gpa, io, repo_dir);
    return context;
}

pub fn resolveRevision(
    io: std.Io,
    gpa: std.mem.Allocator,
    repo_dir: std.Io.Dir,
    revision: []const u8,
) !?[]const u8 {
    const rev_arg = try std.fmt.allocPrint(gpa, "{s}^{{commit}}", .{revision});
    defer gpa.free(rev_arg);
    return runGitTrimmedAlloc(gpa, io, repo_dir, &.{
        "git",
        "rev-parse",
        "--verify",
        rev_arg,
    });
}

pub fn listRangeCommits(
    io: std.Io,
    gpa: std.mem.Allocator,
    repo_dir: std.Io.Dir,
    from_revision: []const u8,
    to_revision: []const u8,
) !?[]const []const u8 {
    const range_arg = try std.fmt.allocPrint(gpa, "{s}..{s}", .{ from_revision, to_revision });
    defer gpa.free(range_arg);
    const stdout = try runGitAlloc(gpa, io, repo_dir, &.{
        "git",
        "rev-list",
        "--reverse",
        range_arg,
    }, std.Io.Limit.limited(1024 * 1024)) orelse return null;
    defer gpa.free(stdout);

    var commits: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (commits.items) |commit| gpa.free(commit);
        commits.deinit(gpa);
    }

    var it = std.mem.tokenizeAny(u8, stdout, "\r\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        try commits.append(gpa, try gpa.dupe(u8, trimmed));
    }

    const owned = try commits.toOwnedSlice(gpa);
    return owned;
}

pub fn freeCommitList(gpa: std.mem.Allocator, commits: []const []const u8) void {
    for (commits) |commit| gpa.free(commit);
    gpa.free(commits);
}

fn runGitTrimmedAlloc(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo_dir: std.Io.Dir,
    argv: []const []const u8,
) !?[]const u8 {
    const stdout = try runGitAlloc(gpa, io, repo_dir, argv, small_output_limit) orelse return null;
    defer gpa.free(stdout);
    const trimmed = std.mem.trim(u8, stdout, " \r\n\t");
    return try gpa.dupe(u8, trimmed);
}

fn runGitDirty(gpa: std.mem.Allocator, io: std.Io, repo_dir: std.Io.Dir) !?bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "status", "--porcelain=v1" },
        .cwd = .{ .dir = repo_dir },
        .stdout_limit = std.Io.Limit.limited(1),
        .stderr_limit = small_output_limit,
        .reserve_amount = 1,
        .timeout = git_timeout,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.StreamTooLong => return true,
        error.FileNotFound,
        error.Timeout,
        error.AccessDenied,
        error.NameTooLong,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.InvalidExe,
        error.Unexpected,
        => return null,
        else => return null,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) return null;
    return result.stdout.len > 0;
}

fn runGitAlloc(
    gpa: std.mem.Allocator,
    io: std.Io,
    repo_dir: std.Io.Dir,
    argv: []const []const u8,
    stdout_limit: std.Io.Limit,
) !?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = repo_dir },
        .stdout_limit = stdout_limit,
        .stderr_limit = small_output_limit,
        .timeout = git_timeout,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.FileNotFound,
        error.Timeout,
        error.AccessDenied,
        error.NameTooLong,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.StreamTooLong,
        error.InvalidExe,
        error.Unexpected,
        => return null,
        else => return null,
    };
    defer gpa.free(result.stderr);
    errdefer gpa.free(result.stdout);

    if (result.term != .exited or result.term.exited != 0) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

fn gitAvailable(io: std.Io, gpa: std.mem.Allocator) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "--version" },
        .stdout_limit = small_output_limit,
        .stderr_limit = small_output_limit,
        .timeout = git_timeout,
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn runRequiredGit(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
        .timeout = git_timeout,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

test "captureContext returns null fields outside git repository" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var git_file = try tmp.dir.createFile(io, ".git", .{});
    try git_file.writeStreamingAll(io, "gitdir: /definitely/not/a/git/dir\n");
    git_file.close(io);
    var context = try captureContext(io, std.testing.allocator, tmp.dir);
    defer context.deinit(std.testing.allocator);
    try std.testing.expect(context.commit == null);
    try std.testing.expect(context.branch == null);
    try std.testing.expect(context.dirty == null);
}

test "captureContext records commit branch and dirty state in git repository" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    if (!gitAvailable(io, gpa)) return;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try runRequiredGit(io, gpa, tmp.dir, &.{ "git", "init", "-b", "main" });
    try runRequiredGit(io, gpa, tmp.dir, &.{ "git", "config", "user.email", "agit@example.test" });
    try runRequiredGit(io, gpa, tmp.dir, &.{ "git", "config", "user.name", "agit" });
    try runRequiredGit(io, gpa, tmp.dir, &.{ "git", "config", "commit.gpgsign", "false" });

    var file = try tmp.dir.createFile(io, "file.txt", .{});
    try file.writeStreamingAll(io, "one\n");
    file.close(io);
    try runRequiredGit(io, gpa, tmp.dir, &.{ "git", "add", "file.txt" });
    try runRequiredGit(io, gpa, tmp.dir, &.{ "git", "commit", "-m", "initial" });

    var clean = try captureContext(io, gpa, tmp.dir);
    defer clean.deinit(gpa);
    try std.testing.expect(clean.commit != null);
    try std.testing.expectEqualStrings("main", clean.branch.?);
    try std.testing.expectEqual(false, clean.dirty.?);

    var dirty_file = try tmp.dir.createFile(io, "file.txt", .{ .truncate = true });
    defer dirty_file.close(io);
    try dirty_file.writeStreamingAll(io, "two\n");

    var dirty = try captureContext(io, gpa, tmp.dir);
    defer dirty.deinit(gpa);
    try std.testing.expectEqual(true, dirty.dirty.?);
}

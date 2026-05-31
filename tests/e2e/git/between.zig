const std = @import("std");
const harness = @import("../support/harness.zig");

const git_timeout: std.Io.Timeout = .{
    .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(5000),
        .clock = .awake,
    },
};

test "between lists recorded steps captured in a git range" {
    if (!gitAvailable()) return;

    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try runGit(sandbox.cwd, &.{ "git", "init", "-b", "main" });
    try runGit(sandbox.cwd, &.{ "git", "config", "user.email", "agit@example.test" });
    try runGit(sandbox.cwd, &.{ "git", "config", "user.name", "agit" });
    try runGit(sandbox.cwd, &.{ "git", "config", "commit.gpgsign", "false" });

    try sandbox.writeRepoFile("file.txt", "base\n");
    try runGit(sandbox.cwd, &.{ "git", "add", "file.txt" });
    try runGit(sandbox.cwd, &.{ "git", "commit", "-m", "base" });
    const base = try revParse(sandbox.cwd, "HEAD");
    defer std.testing.allocator.free(base);

    try sandbox.writeRepoFile("file.txt", "base\nagent one\n");
    try recordTurn(&sandbox, "git-range-sess", "turn-a", "make the first change", "first change done");
    try runGit(sandbox.cwd, &.{ "git", "add", "file.txt" });
    try runGit(sandbox.cwd, &.{ "git", "commit", "-m", "change one" });
    const change_one = try revParse(sandbox.cwd, "HEAD");
    defer std.testing.allocator.free(change_one);

    try recordTurn(&sandbox, "git-range-sess", "turn-b", "inspect the committed change", "inspection done");

    try sandbox.writeRepoFile("file.txt", "base\nagent one\nagent two\n");
    try runGit(sandbox.cwd, &.{ "git", "add", "file.txt" });
    try runGit(sandbox.cwd, &.{ "git", "commit", "-m", "change two" });
    try recordTurn(&sandbox, "git-range-sess", "turn-c", "make the second change", "second change done");

    var between = try sandbox.run(&.{ "between", base, change_one }, null);
    defer between.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), between.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, between.stdout, "git-range-sess") != null);
    try std.testing.expect(std.mem.indexOf(u8, between.stdout, "turn turn-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, between.stdout, "turn turn-b") != null);
    try std.testing.expect(std.mem.indexOf(u8, between.stdout, "turn turn-c") == null);

    var json = try sandbox.run(&.{ "between", "--json", base, change_one }, null);
    defer json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), json.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "\"schema_version\":\"cli-json-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.stdout, "\"steps_without_git_commit\":0") != null);
}

test "between reports pre-ADR steps without git context" {
    if (!gitAvailable()) return;

    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try runGit(sandbox.cwd, &.{ "git", "init", "-b", "main" });
    try runGit(sandbox.cwd, &.{ "git", "config", "user.email", "agit@example.test" });
    try runGit(sandbox.cwd, &.{ "git", "config", "user.name", "agit" });
    try runGit(sandbox.cwd, &.{ "git", "config", "commit.gpgsign", "false" });
    try sandbox.writeRepoFile("file.txt", "base\n");
    try runGit(sandbox.cwd, &.{ "git", "add", "file.txt" });
    try runGit(sandbox.cwd, &.{ "git", "commit", "-m", "base" });
    const base = try revParse(sandbox.cwd, "HEAD");
    defer std.testing.allocator.free(base);

    var status = try sandbox.run(&.{"status"}, null);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), status.exit_code);

    try insertLegacyStep(&sandbox);

    try sandbox.writeRepoFile("file.txt", "base\nnext\n");
    try runGit(sandbox.cwd, &.{ "git", "add", "file.txt" });
    try runGit(sandbox.cwd, &.{ "git", "commit", "-m", "next" });
    const next = try revParse(sandbox.cwd, "HEAD");
    defer std.testing.allocator.free(next);

    var between = try sandbox.run(&.{ "between", base, next }, null);
    defer between.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), between.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, between.stdout, "1 recorded step(s) have no git commit context") != null);
}

test "hook remains fail-open when git is absent from PATH" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    const payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"no-git","turn_id":"turn-1","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(payload);

    var result = try sandbox.runWithEnv(&.{"codex-hook"}, payload, &.{"PATH=/definitely/no/git"});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

fn recordTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    assistant: []const u8,
) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, prompt });
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, assistant });
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{"codex-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{"codex-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);
}

fn insertLegacyStep(sandbox: *harness.Sandbox) !void {
    var script: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer script.deinit();
    try script.writer.print(
        \\import sqlite3
        \\conn = sqlite3.connect(r"{s}/.agit/index.db")
        \\conn.execute("insert or replace into sessions(origin, session_id, head_hash) values (?, ?, ?)", ("legacy", "legacy-session", "a" * 64))
        \\conn.execute("insert or ignore into steps(hash, session_origin, session_id, turn_id, parent_hash, tree_hash, timestamp) values (?, ?, ?, ?, ?, ?, ?)", ("a" * 64, "legacy", "legacy-session", "turn-legacy", None, "b" * 64, 1))
        \\conn.commit()
        \\conn.close()
        \\
    , .{sandbox.cwd});
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "python3", "-c", script.writer.buffered() },
        .stdout_limit = std.Io.Limit.limited(16 * 1024),
        .stderr_limit = std.Io.Limit.limited(16 * 1024),
        .timeout = git_timeout,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

fn revParse(cwd: []const u8, revision: []const u8) ![]u8 {
    var result = try runGitResult(cwd, &.{ "git", "rev-parse", "--verify", revision });
    defer result.deinit(std.testing.allocator);
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    return try std.testing.allocator.dupe(u8, trimmed);
}

fn runGit(cwd: []const u8, argv: []const []const u8) !void {
    var result = try runGitResult(cwd, argv);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

fn runGitResult(cwd: []const u8, argv: []const []const u8) !harness.RunResult {
    const child = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = std.Io.Limit.limited(64 * 1024),
        .stderr_limit = std.Io.Limit.limited(64 * 1024),
        .timeout = git_timeout,
    });
    errdefer std.testing.allocator.free(child.stdout);
    errdefer std.testing.allocator.free(child.stderr);
    const exit_code: u8 = switch (child.term) {
        .exited => |code| code,
        else => 255,
    };
    return .{
        .stdout = child.stdout,
        .stderr = child.stderr,
        .exit_code = exit_code,
    };
}

fn gitAvailable() bool {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "git", "--version" },
        .stdout_limit = std.Io.Limit.limited(4096),
        .stderr_limit = std.Io.Limit.limited(4096),
        .timeout = git_timeout,
    }) catch return false;
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

const std = @import("std");
const harness = @import("../support/harness.zig");

test "watch streams newly finalized steps and exits cleanly on interrupt" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    var watch = try startWatch(&sandbox, &.{ "watch", "--interval", "50ms" }, "watch.out", "watch.err");
    defer watch.kill(sandbox.io);

    try std.Io.sleep(sandbox.io, std.Io.Duration.fromMilliseconds(100), .awake);
    try sandbox.writeRepoFile("file.txt", "hello\n");
    try recordTurn(&sandbox, "sess-watch", "turn-1", "watch prompt", "watch done");

    try waitForFileContains(&sandbox, "watch.out", "watch prompt", 5000);
    const term = try interruptAndWait(&sandbox, &watch);
    try std.testing.expect(term == .exited and term.exited == 0);

    const out = try sandbox.readRepoFileAlloc("watch.out");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "codex/sess-watch") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Watched 1 step.") != null);
}

test "watch applies session filters" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    var watch = try startWatch(&sandbox, &.{ "watch", "--session", "codex/sess-target", "--interval", "50ms" }, "watch-filter.out", "watch-filter.err");
    defer watch.kill(sandbox.io);

    try std.Io.sleep(sandbox.io, std.Io.Duration.fromMilliseconds(100), .awake);
    try sandbox.writeRepoFile("other.txt", "other\n");
    try recordTurn(&sandbox, "sess-other", "turn-1", "other prompt", "other done");
    try sandbox.writeRepoFile("target.txt", "target\n");
    try recordTurn(&sandbox, "sess-target", "turn-1", "target prompt", "target done");

    try waitForFileContains(&sandbox, "watch-filter.out", "target prompt", 5000);
    const term = try interruptAndWait(&sandbox, &watch);
    try std.testing.expect(term == .exited and term.exited == 0);

    const out = try sandbox.readRepoFileAlloc("watch-filter.out");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "target prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "other prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Watched 1 step.") != null);
}

test "watch emits json lines for historical since output" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("file.txt", "json\n");
    try recordTurn(&sandbox, "sess-json", "turn-1", "json prompt", "json done");

    var watch = try startWatch(&sandbox, &.{ "watch", "--json", "--since", "1970-01-01", "--interval", "50ms" }, "watch-json.out", "watch-json.err");
    defer watch.kill(sandbox.io);

    try waitForFileContains(&sandbox, "watch-json.out", "\"event\":\"step\"", 5000);
    const term = try interruptAndWait(&sandbox, &watch);
    try std.testing.expect(term == .exited and term.exited == 0);

    const out = try sandbox.readRepoFileAlloc("watch-json.out");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"schema_version\":\"cli-json-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"command\":\"watch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"event\":\"summary\"") != null);
}

test "watch exits cleanly on interrupt with an empty store" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    var watch = try startWatch(&sandbox, &.{ "watch", "--interval", "50ms" }, "watch-empty.out", "watch-empty.err");
    defer watch.kill(sandbox.io);

    try std.Io.sleep(sandbox.io, std.Io.Duration.fromMilliseconds(150), .awake);
    const term = try interruptAndWait(&sandbox, &watch);
    try std.testing.expect(term == .exited and term.exited == 0);

    const out = try sandbox.readRepoFileAlloc("watch-empty.out");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("Watched 0 steps.\n", out);
}

fn startWatch(
    sandbox: *harness.Sandbox,
    argv: []const []const u8,
    stdout_rel: []const u8,
    stderr_rel: []const u8,
) !std.process.Child {
    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(sandbox.gpa);

    const home_env = try std.fmt.allocPrint(sandbox.gpa, "HOME={s}", .{sandbox.home});
    defer sandbox.gpa.free(home_env);
    const path_env = try std.fmt.allocPrint(sandbox.gpa, "PATH={s}:/usr/bin:/bin", .{sandbox.bin});
    defer sandbox.gpa.free(path_env);

    try child_argv.appendSlice(sandbox.gpa, &.{ "/usr/bin/env", home_env, path_env, sandbox.agit_bin });
    try child_argv.appendSlice(sandbox.gpa, argv);

    const stdout_path = try std.fmt.allocPrint(sandbox.gpa, "{s}/{s}", .{ sandbox.cwd, stdout_rel });
    defer sandbox.gpa.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(sandbox.gpa, "{s}/{s}", .{ sandbox.cwd, stderr_rel });
    defer sandbox.gpa.free(stderr_path);

    var stdout_file = try std.Io.Dir.cwd().createFile(sandbox.io, stdout_path, .{ .truncate = true });
    errdefer stdout_file.close(sandbox.io);
    var stderr_file = try std.Io.Dir.cwd().createFile(sandbox.io, stderr_path, .{ .truncate = true });
    errdefer stderr_file.close(sandbox.io);

    const child = try std.process.spawn(sandbox.io, .{
        .argv = child_argv.items,
        .cwd = .{ .path = sandbox.cwd },
        .stdin = .ignore,
        .stdout = .{ .file = stdout_file },
        .stderr = .{ .file = stderr_file },
        .create_no_window = true,
    });

    // Keep files open - they're owned by the child process now and will be closed when child exits.
    return child;
}

fn interruptAndWait(sandbox: *harness.Sandbox, child: *std.process.Child) !std.process.Child.Term {
    if (child.id) |pid| try std.posix.kill(pid, .INT);
    return try child.wait(sandbox.io);
}

fn waitForFileContains(sandbox: *harness.Sandbox, rel_path: []const u8, needle: []const u8, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (elapsed <= timeout_ms) : (elapsed += 50) {
        if (sandbox.readRepoFileAlloc(rel_path)) |content| {
            defer std.testing.allocator.free(content);
            if (std.mem.indexOf(u8, content, needle) != null) return;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.sleep(sandbox.io, std.Io.Duration.fromMilliseconds(50), .awake);
    }
    return error.TimedOut;
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

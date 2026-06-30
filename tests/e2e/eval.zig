const std = @import("std");
const harness = @import("support/harness.zig");

test "eval/json reports dimension ratings for a verified session" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-good",
        "turn-1",
        "Add an eval command that reports JSON and run zig build test",
        "bash",
        "zig build test",
        "All 42 tests passed",
        "Implemented eval command and verified with zig build test.",
    );

    var result = try sandbox.run(&.{ "eval", "--json", "--session", "codex/eval-good", "--no-lookahead" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const data = parsed.value.object.get("data").?.object;
    // eval_hash must be present and a 64-char hex string
    const eval_hash = data.get("eval_hash").?.string;
    try std.testing.expectEqual(@as(usize, 64), eval_hash.len);

    try std.testing.expectEqualStrings("good", data.get("current_assessment").?.object.get("classification").?.string);

    const dimensions = data.get("in_scope_assessment").?.object.get("dimensions").?.object;
    try std.testing.expectEqualStrings("good", dimensions.get("goal_clarity").?.object.get("rating").?.string);
    try std.testing.expectEqualStrings("good", dimensions.get("verification").?.object.get("rating").?.string);
    try std.testing.expect(dimensions.get("verification").?.object.get("signals").?.object.get("verification_commands").?.integer >= 1);
}

test "eval/json flags repeated failures and churn risk" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-bad",
        "turn-1",
        "Fix it",
        "bash",
        "zig build test",
        "error: workflow failed",
        "Still working on it.",
    );
    try recordCodexTurn(
        &sandbox,
        "eval-bad",
        "turn-2",
        "Try again",
        "bash",
        "zig build test",
        "error: workflow failed",
        "Done.",
    );

    var result = try sandbox.run(&.{ "eval", "--json", "--session", "codex/eval-bad", "--no-lookahead" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const data = parsed.value.object.get("data").?.object;
    // eval_hash must be present and a 64-char hex string
    const eval_hash = data.get("eval_hash").?.string;
    try std.testing.expectEqual(@as(usize, 64), eval_hash.len);

    const dimensions = data.get("in_scope_assessment").?.object.get("dimensions").?.object;
    try std.testing.expectEqualStrings("bad", dimensions.get("goal_clarity").?.object.get("rating").?.string);
    try std.testing.expectEqualStrings("bad", dimensions.get("failure_recovery").?.object.get("rating").?.string);
    try std.testing.expectEqualStrings("bad", dimensions.get("churn_risk").?.object.get("rating").?.string);
}

test "eval/json lookahead downgrades an earlier good-looking session" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-earlier",
        "turn-1",
        "Fix the workflow failure and run zig build test",
        "bash",
        "zig build test",
        "All tests passed",
        "Fixed the workflow and verified tests passed.",
    );
    try recordCodexTurn(
        &sandbox,
        "eval-later",
        "turn-1",
        "The workflow has failed again after that change",
        "bash",
        "cat .github/workflows/ci.yml",
        "workflow failed on CI",
        "I will investigate the CI failure.",
    );

    var result = try sandbox.run(&.{ "eval", "--json", "--session", "codex/eval-earlier", "--lookahead", "24h" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const data = parsed.value.object.get("data").?.object;
    // eval_hash must be present and a 64-char hex string
    const eval_hash = data.get("eval_hash").?.string;
    try std.testing.expectEqual(@as(usize, 64), eval_hash.len);

    try std.testing.expectEqualStrings("downgrade", data.get("follow_up_assessment").?.object.get("classification_delta").?.string);
    try std.testing.expect(data.get("follow_up_assessment").?.object.get("signals").?.array.items.len >= 1);
    try std.testing.expectEqualStrings("mixed", data.get("current_assessment").?.object.get("classification").?.string);
}

test "eval/json supports inferred git commit scope" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try git(&sandbox, &.{ "init", "-q" });
    try git(&sandbox, &.{ "config", "user.email", "test@example.com" });
    try git(&sandbox, &.{ "config", "user.name", "Test User" });
    try git(&sandbox, &.{ "config", "commit.gpgsign", "false" });
    try sandbox.writeRepoFile("README.md", "initial\n");
    try git(&sandbox, &.{ "add", "README.md" });
    try git(&sandbox, &.{ "commit", "-q", "-m", "initial" });

    try recordCodexTurn(
        &sandbox,
        "eval-commit",
        "turn-1",
        "Fix the workflow and run zig build test",
        "bash",
        "zig build test",
        "All tests passed",
        "Fixed the workflow and verified tests passed.",
    );
    try sandbox.writeRepoFile("README.md", "initial\nupdated\n");
    try git(&sandbox, &.{ "add", "README.md" });
    try git(&sandbox, &.{ "commit", "-q", "-m", "update readme" });

    var result = try sandbox.run(&.{ "eval", "--json", "--commit", "HEAD", "--no-lookahead" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const data = parsed.value.object.get("data").?.object;
    // eval_hash must be present and a 64-char hex string
    const eval_hash = data.get("eval_hash").?.string;
    try std.testing.expectEqual(@as(usize, 64), eval_hash.len);

    const scope_value = data.get("scope") orelse return error.TestUnexpectedResult;
    const scope = scope_value.object;
    try std.testing.expectEqualStrings("commit", scope.get("kind").?.string);
    try std.testing.expectEqualStrings("HEAD", scope.get("rev").?.string);
    try std.testing.expectEqual(@as(i64, 1), scope.get("step_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), scope.get("session_count").?.integer);
    try std.testing.expectEqualStrings("medium", data.get("association_confidence").?.string);
    try std.testing.expectEqualStrings("good", data.get("current_assessment").?.object.get("classification").?.string);
}

test "eval/json applies date filters to explicit session scopes" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-filtered",
        "turn-1",
        "Add JSON output and run zig build test",
        "bash",
        "zig build test",
        "All tests passed",
        "Implemented JSON output and verified tests passed.",
    );

    var result = try sandbox.run(&.{ "eval", "--json", "--session", "codex/eval-filtered", "--until", "1970-01-01", "--no-lookahead" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const diagnostic = parsed.value.object.get("data").?.object.get("diagnostic").?.object;
    try std.testing.expectEqualStrings("session_not_found", diagnostic.get("code").?.string);
}

test "eval/json window scopes include multiple matching sessions" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-window-a",
        "turn-1",
        "Add JSON output and run zig build test",
        "bash",
        "zig build test",
        "All tests passed",
        "Implemented JSON output and verified tests passed.",
    );
    try recordCodexTurn(
        &sandbox,
        "eval-window-b",
        "turn-1",
        "Fix eval scoring and run zig build test",
        "bash",
        "zig build test",
        "All tests passed",
        "Fixed eval scoring and verified tests passed.",
    );

    var result = try sandbox.run(&.{ "eval", "--json", "--since", "1970-01-01", "--no-lookahead" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const data = parsed.value.object.get("data").?.object;
    // eval_hash must be present and a 64-char hex string
    const eval_hash = data.get("eval_hash").?.string;
    try std.testing.expectEqual(@as(usize, 64), eval_hash.len);

    const scope = data.get("scope").?.object;
    try std.testing.expectEqualStrings("window", scope.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), scope.get("step_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), scope.get("session_count").?.integer);
    try std.testing.expectEqualStrings("good", data.get("current_assessment").?.object.get("classification").?.string);
}

test "eval/json pattern associations come from scoped evidence" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-pattern",
        "turn-1",
        "Add eval JSON and run zig build test",
        "bash",
        "zig build test",
        "All tests passed",
        "Implemented eval JSON and verified tests passed.",
    );

    var result = try sandbox.run(&.{ "eval", "--json", "--session", "codex/eval-pattern", "--no-lookahead" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const patterns = parsed.value.object.get("data").?.object.get("patterns").?.array.items;
    try std.testing.expect(patterns.len >= 1);
    try std.testing.expectEqualStrings("verification command", patterns[0].object.get("phrase").?.string);
    try std.testing.expectEqualStrings("tool_args", patterns[0].object.get("source").?.string);
    try std.testing.expectEqual(@as(i64, 1), patterns[0].object.get("support").?.integer);
}

test "eval/json includes per-step signals with --include-steps" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-steps",
        "turn-1",
        "Add JSON output and run zig build test",
        "bash",
        "zig build test",
        "All tests passed",
        "Implemented JSON output and verified tests passed.",
    );
    try recordCodexTurn(
        &sandbox,
        "eval-steps",
        "turn-2",
        "Fix a thing",
        "bash",
        "zig build test",
        "error: something broke",
        "Will fix it.",
    );

    var result = try sandbox.run(&.{ "eval", "--json", "--session", "codex/eval-steps", "--include-steps", "--no-lookahead" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const data = parsed.value.object.get("data").?.object;
    const step_assessments = data.get("step_assessments").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), step_assessments.len);

    // First step should have verification and tool calls
    const first = step_assessments[0].object;
    try std.testing.expectEqual(@as(usize, 64), first.get("hash").?.string.len);
    const first_signals = first.get("signals").?.object;
    try std.testing.expect(first_signals.get("tool_calls").?.integer >= 1);

    // Second step should have error_results
    const second = step_assessments[1].object;
    const second_signals = second.get("signals").?.object;
    try std.testing.expect(second_signals.get("error_results").?.integer >= 1);
}

test "eval/json --list returns stored evaluations" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "eval-list",
        "turn-1",
        "Add a feature",
        "bash",
        "echo done",
        "done",
        "Feature added.",
    );

    // Run eval to create a stored evaluation object.
    var eval_result = try sandbox.run(&.{ "eval", "--json", "--session", "codex/eval-list", "--no-lookahead" }, null);
    defer eval_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), eval_result.exit_code);

    // Now list evaluations.
    var result = try sandbox.run(&.{ "eval", "--json", "--list" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "eval");

    const data = parsed.value.object.get("data").?.object;
    const evals = data.get("evals").?.array.items;
    try std.testing.expect(evals.len >= 1);

    const first_eval = evals[0].object;
    try std.testing.expectEqual(@as(usize, 64), first_eval.get("eval_hash").?.string.len);
    try std.testing.expectEqualStrings("session", first_eval.get("scope_type").?.string);
    try std.testing.expectEqualStrings("codex/eval-list", first_eval.get("scope_key").?.string);
}

fn recordCodexTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    tool_name: []const u8,
    command: []const u8,
    tool_result: []const u8,
    assistant: []const u8,
) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, prompt });
    defer std.testing.allocator.free(user_payload);
    const tool_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"PostToolUse","tool_name":"{s}","tool_input":{{"command":"{s}"}},"tool_use_id":"tool-{s}","tool_response":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, tool_name, command, turn_id, tool_result });
    defer std.testing.allocator.free(tool_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, assistant });
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{"codex-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var tool_res = try sandbox.run(&.{"codex-hook"}, tool_payload);
    defer tool_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), tool_res.exit_code);

    var stop_res = try sandbox.run(&.{"codex-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);
}

fn git(sandbox: *harness.Sandbox, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(std.testing.allocator);
    try argv.append(std.testing.allocator, "/usr/bin/git");
    try argv.appendSlice(std.testing.allocator, args);

    var child = try std.process.spawn(std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .path = sandbox.cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(std.testing.io);

    var stdout_reader_buf: [1024]u8 = undefined;
    var stderr_reader_buf: [1024]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(std.testing.io, &stdout_reader_buf);
    var stderr_reader = child.stderr.?.reader(std.testing.io, &stderr_reader_buf);
    const stdout = try stdout_reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(stdout);
    const stderr = try stderr_reader.interface.allocRemaining(std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(stderr);

    child.stdout.?.close(std.testing.io);
    child.stdout = null;
    child.stderr.?.close(std.testing.io);
    child.stderr = null;

    const term = try child.wait(std.testing.io);
    if (!(term == .exited and term.exited == 0)) {
        std.debug.print("git failed: {s}\nstdout: {s}\nstderr: {s}\n", .{ args[0], stdout, stderr });
        return error.TestUnexpectedResult;
    }
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

fn expectEnvelope(root: std.json.Value, command: []const u8) !void {
    try std.testing.expectEqualStrings("cli-json-v1", root.object.get("schema_version").?.string);
    try std.testing.expectEqualStrings(command, root.object.get("command").?.string);
    try std.testing.expect(root.object.get("data") != null);
}

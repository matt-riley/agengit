const std = @import("std");
const harness = @import("../support/harness.zig");

test "recall/path returns prior path-scoped steps with outcome-aware ranking" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("app.txt", "alpha\n");
    try recordTurn(&sandbox, "recall-sess", "turn-1", "first attempt", "error: tests failed");

    try sandbox.writeRepoFile("app.txt", "alpha\nbeta\n");
    try recordTurn(&sandbox, "recall-sess", "turn-2", "second attempt", "ok");

    try sandbox.writeRepoFile("other.txt", "side quest\n");
    try recordTurn(&sandbox, "other-sess", "turn-3", "unrelated work", "ok");

    var recall = try sandbox.run(&.{ "recall", "--json", "--path", "app.txt" }, null);
    defer recall.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), recall.exit_code);

    var parsed = try parseJson(recall.stdout);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("recall", parsed.value.object.get("command").?.string);

    const matches = parsed.value.object.get("data").?.object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("turn-1", matches[0].object.get("turn_id").?.string);
    try std.testing.expectEqualStrings("failure", matches[0].object.get("outcome").?.string);
    try std.testing.expectEqualStrings("turn-2", matches[1].object.get("turn_id").?.string);
    try std.testing.expectEqualStrings("success", matches[1].object.get("outcome").?.string);

    var failures_only = try sandbox.run(&.{ "recall", "--json", "--path", "app.txt", "--outcome", "failure" }, null);
    defer failures_only.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), failures_only.exit_code);

    var failures_json = try parseJson(failures_only.stdout);
    defer failures_json.deinit();
    const failure_matches = failures_json.value.object.get("data").?.object.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), failure_matches.len);
    try std.testing.expectEqualStrings("turn-1", failure_matches[0].object.get("turn_id").?.string);
}

test "recall/judged filters sessions by latest eval classification" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("src/a.zig", "const a = 1;\n");

    // Record a "good" session.
    try recordTurn(&sandbox, "good-sess", "good-turn", "Implement the feature and run zig build test", "All 42 tests passed");
    // Record a "bad" session.
    try recordTurn(&sandbox, "bad-sess", "bad-turn", "Fix it", "error: workflow failed");
    try recordTurn(&sandbox, "bad-sess", "bad-turn2", "Try again", "error: workflow failed");

    // Run eval for both sessions to produce eval objects.
    var eval_good = try sandbox.run(&.{ "eval", "--json", "--session", "codex/good-sess", "--no-lookahead" }, null);
    defer eval_good.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), eval_good.exit_code);

    var eval_bad = try sandbox.run(&.{ "eval", "--json", "--session", "codex/bad-sess", "--no-lookahead" }, null);
    defer eval_bad.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), eval_bad.exit_code);

    // recall --judged good should return only the good session.
    var recall_good = try sandbox.run(&.{ "recall", "--json", "--path", "src/a.zig", "--judged", "good" }, null);
    defer recall_good.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), recall_good.exit_code);

    var good_json = try parseJson(recall_good.stdout);
    defer good_json.deinit();
    const good_matches = good_json.value.object.get("data").?.object.get("matches").?.array.items;
    for (good_matches) |match| {
        try std.testing.expectEqualStrings("codex", match.object.get("origin").?.string);
        try std.testing.expect(!std.mem.eql(u8, match.object.get("session_id").?.string, "bad-sess"));
    }

    // recall --judged bad should return only the bad session.
    var recall_bad = try sandbox.run(&.{ "recall", "--json", "--path", "src/a.zig", "--judged", "bad" }, null);
    defer recall_bad.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), recall_bad.exit_code);

    var bad_json = try parseJson(recall_bad.stdout);
    defer bad_json.deinit();
    const bad_matches = bad_json.value.object.get("data").?.object.get("matches").?.array.items;
    for (bad_matches) |match| {
        try std.testing.expectEqualStrings("codex", match.object.get("origin").?.string);
        try std.testing.expect(!std.mem.eql(u8, match.object.get("session_id").?.string, "good-sess"));
    }
}

fn recordTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    tool_response: []const u8,
) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, prompt });
    defer std.testing.allocator.free(user_payload);
    const tool_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"PostToolUse","tool_name":"bash","tool_input":{{"command":"test"}},"tool_response":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, tool_response });
    defer std.testing.allocator.free(tool_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"done"}}
    , .{ session_id, turn_id, sandbox.cwd });
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

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

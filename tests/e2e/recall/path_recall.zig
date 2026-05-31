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

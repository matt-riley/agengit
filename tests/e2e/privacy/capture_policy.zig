const std = @import("std");
const harness = @import("../support/harness.zig");

test "privacy/capture_policy metadata-only tool results" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/config.json",
        \\{
        \\  "version": 1,
        \\  "privacy": {
        \\    "capture": {
        \\      "tool_results": "metadata_only"
        \\    }
        \\  }
        \\}
    );

    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"privacy-sess","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"debug auth"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const tool_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"privacy-sess","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"PostToolBatch","tool_calls":[{{"tool_name":"Bash","tool_input":{{"command":"printenv TOKEN"}},"tool_use_id":"toolu_01","tool_response":"secret-token-value"}}]}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(tool_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"privacy-sess","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{ "claude-hook", "user" }, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var tool_res = try sandbox.run(&.{"claude-tool-batch-hook"}, tool_payload);
    defer tool_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), tool_res.exit_code);

    var stop_res = try sandbox.run(&.{ "claude-hook", "assistant" }, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    var log_result = try sandbox.run(&.{ "log", "--json" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    const step_hash = try extractFirstStepHash(log_result.stdout);
    defer std.testing.allocator.free(step_hash);

    var show_result = try sandbox.run(&.{ "show", "--json", step_hash }, null);
    defer show_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), show_result.exit_code);

    var parsed = try parseJson(show_result.stdout);
    defer parsed.deinit();
    const tool_calls = parsed.value.object.get("data").?.object.get("step").?.object.get("tool_calls").?.array.items;
    const result = tool_calls[0].object.get("result").?.string;
    try std.testing.expect(std.mem.indexOf(u8, result, "metadata-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "secret-token-value") == null);
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

fn extractFirstStepHash(data: []const u8) ![]const u8 {
    var parsed = try parseJson(data);
    defer parsed.deinit();
    const steps = parsed.value.object.get("data").?.object.get("steps").?.array.items;
    return try std.testing.allocator.dupe(u8, steps[0].object.get("hash").?.string);
}

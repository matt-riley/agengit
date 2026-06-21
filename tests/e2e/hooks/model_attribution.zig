const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/model_attribution codex model reaches show log and blame" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("file.txt", "model line\n");

    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"model-sess","turn_id":"turn-1","cwd":"{s}","hook_event_name":"UserPromptSubmit","model":"gpt-5-codex","prompt":"capture model"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"model-sess","turn_id":"turn-1","cwd":"{s}","hook_event_name":"Stop","model":"gpt-5-codex","last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{"codex-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{"codex-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    var log_json = try sandbox.run(&.{ "log", "--json", "codex/model-sess" }, null);
    defer log_json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_json.exit_code);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const step_hash = try expectLogModelAndHash(arena.allocator(), log_json.stdout, "gpt-5-codex");

    var show = try sandbox.run(&.{ "show", step_hash }, null);
    defer show.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), show.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "model     gpt-5-codex") != null);

    var blame = try sandbox.run(&.{ "blame", "--json", "file.txt" }, null);
    defer blame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), blame.exit_code);
    try expectBlameModel(arena.allocator(), blame.stdout, "gpt-5-codex");
}

test "hooks/model_attribution claude session start model is attached to later step" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const session_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"claude-model-sess","cwd":"{s}","hook_event_name":"SessionStart","model":"claude-sonnet-4-6"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(session_payload);
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"claude-model-sess","turn_id":"turn-1","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"capture session model"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"claude-model-sess","turn_id":"turn-1","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var session_res = try sandbox.run(&.{ "claude-hook", "session-start" }, session_payload);
    defer session_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), session_res.exit_code);

    var user_res = try sandbox.run(&.{ "claude-hook", "user" }, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{ "claude-hook", "assistant" }, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    var log_json = try sandbox.run(&.{ "log", "--json", "claude/claude-model-sess" }, null);
    defer log_json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_json.exit_code);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectLogModelAndHash(arena.allocator(), log_json.stdout, "claude-sonnet-4-6");
}

test "hooks/model_attribution gemini before model is attached to matching turn" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const model_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"gemini-model-sess","turn_id":"turn-1","cwd":"{s}","hook_event_name":"BeforeModel","llm_request":{{"model":"gemini-2.5-pro"}}}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(model_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"gemini-model-sess","turn_id":"turn-1","cwd":"{s}","hook_event_name":"AfterAgent","response":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var model_res = try sandbox.run(&.{"gemini-hook"}, model_payload);
    defer model_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), model_res.exit_code);

    var stop_res = try sandbox.run(&.{"gemini-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    var log_json = try sandbox.run(&.{ "log", "--json", "gemini/gemini-model-sess" }, null);
    defer log_json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_json.exit_code);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try expectLogModelAndHash(arena.allocator(), log_json.stdout, "gemini-2.5-pro");
}

fn expectLogModelAndHash(arena: std.mem.Allocator, json: []const u8, expected_model: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{ .allocate = .alloc_always });
    const data = parsed.value.object.get("data").?.object;
    const steps = data.get("steps").?.array;
    try std.testing.expectEqual(@as(usize, 1), steps.items.len);
    const step = steps.items[0].object;
    try std.testing.expectEqualStrings(expected_model, step.get("model").?.string);
    return step.get("hash").?.string;
}

fn expectBlameModel(arena: std.mem.Allocator, json: []const u8, expected_model: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{ .allocate = .alloc_always });
    const data = parsed.value.object.get("data").?.object;
    const lines = data.get("lines").?.array;
    try std.testing.expect(lines.items.len > 0);
    try std.testing.expectEqualStrings(expected_model, lines.items[0].object.get("model").?.string);
}

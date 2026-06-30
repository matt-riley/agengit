const std = @import("std");
const harness = @import("support/harness.zig");

test "steps/json returns metadata for a session" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "steps-session",
        "turn-1",
        "Add a feature and test it",
        "bash",
        "echo hello",
        "hello",
        "Done.",
    );

    var result = try sandbox.run(&.{ "steps", "--json", "steps-session" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "steps");

    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("codex", data.get("origin").?.string);
    try std.testing.expectEqualStrings("steps-session", data.get("session_id").?.string);

    const steps = data.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), steps.len);

    const step = steps[0].object;
    try std.testing.expectEqual(@as(usize, 64), step.get("hash").?.string.len);
    try std.testing.expectEqualStrings("turn-1", step.get("turn_id").?.string);
    try std.testing.expect(step.get("timestamp").?.integer > 0);

    // --include-step-objects defaults to false, so step and diff should be JSON null.
    try std.testing.expect(step.get("step").? == .null);
    try std.testing.expect(step.get("diff").? == .null);
}

test "steps/json includes step objects with --include-step-objects" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "steps-full",
        "turn-1",
        "Add a feature and test it",
        "bash",
        "echo hello",
        "hello",
        "Done.",
    );

    var result = try sandbox.run(&.{ "steps", "--json", "--include-step-objects", "steps-full" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "steps");

    const data = parsed.value.object.get("data").?.object;
    const steps = data.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), steps.len);

    const step = steps[0].object;

    // step object should be present
    const step_obj = step.get("step").?.object;
    const messages = step_obj.get("messages").?.array.items;
    try std.testing.expect(messages.len >= 1);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);

    // diff should be present by default
    const diff = step.get("diff").?.object;
    _ = diff.get("counts").?.object;
    _ = diff.get("changes").?.array;
}

test "steps/json --no-diffs omits diff when flag is set" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "steps-nodiff",
        "turn-1",
        "Add a feature and test it",
        "bash",
        "echo hello",
        "hello",
        "Done.",
    );

    // --include-step-objects with --no-diffs: step present, diff should be null.
    var result = try sandbox.run(&.{ "steps", "--json", "--include-step-objects", "--no-diffs", "steps-nodiff" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "steps");

    const data = parsed.value.object.get("data").?.object;
    const steps = data.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), steps.len);

    const step = steps[0].object;
    // step object should be present (--include-step-objects is set).
    try std.testing.expect(step.get("step") != null);
    // diff should be null because --no-diffs suppresses diff computation.
    try std.testing.expect(step.get("diff") != null);
    try std.testing.expect(step.get("diff").? == .null);
}

test "steps/json returns multiple steps ordered by timestamp" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "steps-multi",
        "turn-1",
        "First task",
        "bash",
        "echo one",
        "one",
        "First done.",
    );
    try recordCodexTurn(
        &sandbox,
        "steps-multi",
        "turn-2",
        "Second task",
        "bash",
        "echo two",
        "two",
        "Second done.",
    );

    var result = try sandbox.run(&.{ "steps", "--json", "steps-multi" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try expectEnvelope(parsed.value, "steps");

    const data = parsed.value.object.get("data").?.object;
    const steps = data.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), steps.len);

    // Steps should be ordered by timestamp ascending.
    const ts1 = steps[0].object.get("timestamp").?.integer;
    const ts2 = steps[1].object.get("timestamp").?.integer;
    try std.testing.expect(ts1 <= ts2);
    // Turn IDs should be in order.
    try std.testing.expectEqualStrings("turn-1", steps[0].object.get("turn_id").?.string);
    try std.testing.expectEqualStrings("turn-2", steps[1].object.get("turn_id").?.string);
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

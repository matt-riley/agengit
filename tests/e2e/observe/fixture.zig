const std = @import("std");
const harness = @import("../support/harness.zig");

test "observe/fixture_once_and_resume_without_duplicates" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");

    const first_fixture = try fixtureOneTurn(std.testing.allocator, sandbox.cwd);
    defer std.testing.allocator.free(first_fixture);
    try sandbox.writeRepoFile("observer.json", first_fixture);

    var first = try sandbox.run(&.{ "observe", "--once", "fixture", "--input", "observer.json" }, null);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "processed 3 event(s)") != null);

    var status_after_first = try sandbox.run(&.{"status"}, null);
    defer status_after_first.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_after_first.stdout, "Steps:           1") != null);

    const second_fixture = try fixtureTwoTurns(std.testing.allocator, sandbox.cwd);
    defer std.testing.allocator.free(second_fixture);
    try sandbox.writeRepoFile("observer.json", second_fixture);

    var second = try sandbox.run(&.{ "observe", "--once", "fixture", "--input", "observer.json" }, null);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "processed 3 event(s)") != null);

    var status_after_second = try sandbox.run(&.{"status"}, null);
    defer status_after_second.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_after_second.stdout, "Sessions:        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_after_second.stdout, "Steps:           2") != null);

    var log_result = try sandbox.run(&.{ "log", "--json", "fixture/observer-session" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    var parsed_log = try parseJson(log_result.stdout);
    defer parsed_log.deinit();
    const steps = parsed_log.value.object.get("data").?.object.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
}

test "observe/fixture_respects_metadata_only_tool_results" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");
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
    const fixture = try fixtureOneTurn(std.testing.allocator, sandbox.cwd);
    defer std.testing.allocator.free(fixture);
    try sandbox.writeRepoFile("observer.json", fixture);

    var observe = try sandbox.run(&.{ "observe", "--once", "fixture", "--input", "observer.json" }, null);
    defer observe.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), observe.exit_code);

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
    try std.testing.expect(std.mem.indexOf(u8, result, "secret-tool-result") == null);
}

fn fixtureOneTurn(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "events": [
        \\    {{
        \\      "watermark": "evt-1",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "UserPromptSubmit",
        \\      "kind": "user_prompt",
        \\      "records": [{{ "type": "user_prompt", "content": "first prompt" }}]
        \\    }},
        \\    {{
        \\      "watermark": "evt-2",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "PostToolUse",
        \\      "kind": "tool_use",
        \\      "records": [{{ "type": "tool_use", "tool_name": "bash", "args": "echo first", "result": "secret-tool-result" }}]
        \\    }},
        \\    {{
        \\      "watermark": "evt-3",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "Stop",
        \\      "kind": "assistant",
        \\      "records": [{{ "type": "assistant", "content": "assistant one" }}]
        \\    }}
        \\  ]
        \\}}
    , .{ cwd, cwd, cwd });
}

fn fixtureTwoTurns(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\{{
        \\  "events": [
        \\    {{
        \\      "watermark": "evt-1",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "UserPromptSubmit",
        \\      "kind": "user_prompt",
        \\      "records": [{{ "type": "user_prompt", "content": "first prompt" }}]
        \\    }},
        \\    {{
        \\      "watermark": "evt-2",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "PostToolUse",
        \\      "kind": "tool_use",
        \\      "records": [{{ "type": "tool_use", "tool_name": "bash", "args": "echo first", "result": "secret-tool-result" }}]
        \\    }},
        \\    {{
        \\      "watermark": "evt-3",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "Stop",
        \\      "kind": "assistant",
        \\      "records": [{{ "type": "assistant", "content": "assistant one" }}]
        \\    }},
        \\    {{
        \\      "watermark": "evt-4",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "UserPromptSubmit",
        \\      "kind": "user_prompt",
        \\      "records": [{{ "type": "user_prompt", "content": "second prompt" }}]
        \\    }},
        \\    {{
        \\      "watermark": "evt-5",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "PostToolUse",
        \\      "kind": "tool_use",
        \\      "records": [{{ "type": "tool_use", "tool_name": "bash", "args": "echo second", "result": "second-result" }}]
        \\    }},
        \\    {{
        \\      "watermark": "evt-6",
        \\      "session_id": "observer-session",
        \\      "cwd": "{s}",
        \\      "event_name": "Stop",
        \\      "kind": "assistant",
        \\      "records": [{{ "type": "assistant", "content": "assistant two" }}]
        \\    }}
        \\  ]
        \\}}
    , .{ cwd, cwd, cwd, cwd, cwd, cwd });
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

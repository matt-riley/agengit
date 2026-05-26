const std = @import("std");
const harness = @import("support/harness.zig");

const schema_version = "cli-json-v1";

test "structured_output/status sessions log and show json" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try seedClaudeSession(&sandbox);

    var status_result = try sandbox.run(&.{ "status", "--json" }, null);
    defer status_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), status_result.exit_code);
    try expectEnvelope(status_result.stdout, "status");

    var status_json = try parseJson(status_result.stdout);
    defer status_json.deinit();
    try std.testing.expectEqual(@as(i64, 1), status_json.value.object.get("data").?.object.get("sessions").?.integer);
    try std.testing.expectEqual(@as(i64, 1), status_json.value.object.get("data").?.object.get("steps").?.integer);

    var sessions_result = try sandbox.run(&.{ "sessions", "--json" }, null);
    defer sessions_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), sessions_result.exit_code);
    try expectEnvelope(sessions_result.stdout, "sessions");

    var sessions_json = try parseJson(sessions_result.stdout);
    defer sessions_json.deinit();
    const sessions = sessions_json.value.object.get("data").?.object.get("sessions").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("claude", sessions[0].object.get("origin").?.string);
    try std.testing.expectEqualStrings("abc123def456", sessions[0].object.get("session_id").?.string);

    var log_result = try sandbox.run(&.{ "log", "--json" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    try expectEnvelope(log_result.stdout, "log");

    var log_json = try parseJson(log_result.stdout);
    defer log_json.deinit();
    const steps = log_json.value.object.get("data").?.object.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    const step_hash = steps[0].object.get("hash").?.string;

    var show_result = try sandbox.run(&.{ "show", "--json", step_hash }, null);
    defer show_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), show_result.exit_code);
    try expectEnvelope(show_result.stdout, "show");

    var show_json = try parseJson(show_result.stdout);
    defer show_json.deinit();
    const step = show_json.value.object.get("data").?.object.get("step").?.object;
    try std.testing.expectEqualStrings("claude", step.get("origin").?.string);
    try std.testing.expectEqualStrings("abc123def456", step.get("session_id").?.string);
    try std.testing.expectEqual(@as(usize, 2), step.get("messages").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), step.get("tool_calls").?.array.items.len);

    var grep_result = try sandbox.run(&.{ "grep", "--json", "factorial" }, null);
    defer grep_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), grep_result.exit_code);
    try expectEnvelope(grep_result.stdout, "grep");

    var grep_json = try parseJson(grep_result.stdout);
    defer grep_json.deinit();
    const matches = grep_json.value.object.get("data").?.object.get("matches").?.array.items;
    try std.testing.expect(matches.len >= 1);
    try std.testing.expectEqualStrings("claude", matches[0].object.get("origin").?.string);
}

test "structured_output/doctor json emits stable checks" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    var result = try sandbox.run(&.{ "doctor", "--json" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectEnvelope(result.stdout, "doctor");
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "✓") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "✗") == null);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("data").?.object.get("healthy").?.bool);
    const checks = parsed.value.object.get("data").?.object.get("checks").?.array.items;
    try std.testing.expect(checks.len > 0);
    try std.testing.expect(hasCheckCode(checks, "store_ok"));
    try std.testing.expect(hasCheckCode(checks, "ref_index_drift"));
    try std.testing.expect(hasCheckCode(checks, "object_index_ok"));
}

test "structured_output/fsck json emits stable checks" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try seedClaudeSession(&sandbox);

    var result = try sandbox.run(&.{ "fsck", "--json" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectEnvelope(result.stdout, "fsck");

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("data").?.object.get("healthy").?.bool);
    const checks = parsed.value.object.get("data").?.object.get("checks").?.array.items;
    try std.testing.expect(hasCheckCode(checks, "object_integrity_ok"));
    try std.testing.expect(hasCheckCode(checks, "refs_ok"));
    try std.testing.expect(hasCheckCode(checks, "index_ok"));
}

test "structured_output/gc json emits stable stats" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try seedClaudeSession(&sandbox);

    var result = try sandbox.run(&.{ "gc", "--json", "--grace-hours", "0", "--prune-before", "9999-01-01" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectEnvelope(result.stdout, "gc");

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 1), data.get("refs_pruned").?.integer);
    try std.testing.expect(data.get("reindexed").?.bool);
    try std.testing.expect(data.get("total_objects_before").?.integer > 0);
}

fn seedClaudeSession(sandbox: *harness.Sandbox) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"Write a function to calculate factorial"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const tool_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"PostToolBatch","tool_calls":[{{"tool_name":"Read","tool_input":{{"file_path":"{s}/main.py"}},"tool_use_id":"toolu_01","tool_response":"ok"}},{{"tool_name":"Bash","tool_input":{{"command":"echo 120"}},"tool_use_id":"toolu_02","tool_response":"120\n"}}]}}
    , .{ sandbox.cwd, sandbox.cwd });
    defer std.testing.allocator.free(tool_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}}
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
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

fn expectEnvelope(data: []const u8, command: []const u8) !void {
    var parsed = try parseJson(data);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(schema_version, parsed.value.object.get("schema_version").?.string);
    try std.testing.expectEqualStrings(command, parsed.value.object.get("command").?.string);
    try std.testing.expect(parsed.value.object.get("data") != null);
}

fn hasCheckCode(checks: []const std.json.Value, code: []const u8) bool {
    for (checks) |check| {
        if (std.mem.eql(u8, check.object.get("code").?.string, code)) return true;
    }
    return false;
}

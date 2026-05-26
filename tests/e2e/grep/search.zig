const std = @import("std");
const harness = @import("../support/harness.zig");

test "grep/search filters messages and tool activity" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try seedClaudeSession(&sandbox);
    try seedCodexSession(&sandbox);

    var today_buf: [10]u8 = undefined;
    const today = try currentUtcDate(&today_buf);

    var factorial_result = try sandbox.run(&.{
        "grep",
        "--origin",
        "claude",
        "--session",
        "claude/abc123def456",
        "--since",
        today,
        "--until",
        today,
        "factorial",
    }, null);
    defer factorial_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), factorial_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, factorial_result.stdout, "claude/abc123def456") != null);
    try std.testing.expect(std.mem.indexOf(u8, factorial_result.stdout, "message user") != null);
    try std.testing.expect(std.mem.indexOf(u8, factorial_result.stdout, "codex-sess-001") == null);

    var args_result = try sandbox.run(&.{ "grep", "src/auth.py" }, null);
    defer args_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), args_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, args_result.stdout, "tool args bash") != null);

    var tool_result = try sandbox.run(&.{ "grep", "hashlib" }, null);
    defer tool_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), tool_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, tool_result.stdout, "tool result bash") != null);
}

fn seedClaudeSession(sandbox: *harness.Sandbox) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"Write a function to calculate factorial"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const tool_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"PostToolBatch","tool_calls":[{{"tool_name":"Read","tool_input":{{"file_path":"{s}/main.py"}},"tool_use_id":"toolu_01","tool_response":"def factorial(n: int) -> int:\n"}},{{"tool_name":"Bash","tool_input":{{"command":"python3 -c 'import math; print(math.factorial(5))'"}},"tool_use_id":"toolu_02","tool_response":"120\n"}}]}}
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

fn seedCodexSession(sandbox: *harness.Sandbox) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"codex-sess-001","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"Refactor the auth module to use JWT tokens"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const tool_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"codex-sess-001","cwd":"{s}","hook_event_name":"PostToolUse","tool_name":"bash","tool_input":{{"command":"cat src/auth.py"}},"tool_use_id":"tool-001","tool_response":"import hashlib\n\ndef authenticate(user, password):\n    return hashlib.sha256(password.encode()).hexdigest()\n"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(tool_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"codex-sess-001","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"I've refactored the auth module to use JWT tokens with proper expiry handling."}}
    , .{sandbox.cwd});
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

fn currentUtcDate(buf: *[10]u8) ![]const u8 {
    const now = std.Io.Timestamp.now(std.testing.io, .real);
    const secs: u64 = @intCast(@divTrunc(now.toMilliseconds(), 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const eday = es.getEpochDay();
    const yd = eday.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
    });
}

const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/claude_payloads" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

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

    var status = try sandbox.run(&.{"status"}, null);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Sessions:        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Steps:           1") != null);

    try expectNoHookErrors(&sandbox);
}

fn expectNoHookErrors(sandbox: *harness.Sandbox) !void {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/.agit/log/hook-error.log", .{sandbox.cwd});
    defer std.testing.allocator.free(abs);
    const content = std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer std.testing.allocator.free(content);
    try std.testing.expectEqual(@as(usize, 0), content.len);
}

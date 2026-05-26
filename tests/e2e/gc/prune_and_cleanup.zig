const std = @import("std");
const harness = @import("../support/harness.zig");

test "gc/prune_and_cleanup" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try seedClaudeSession(&sandbox);
    try sandbox.writeRepoFile(".agit/tmp/stale.json", "{}");
    try sandbox.writeRepoFile(".agit/tmp/turns/stale.lock", "{\"pid\":0,\"started_at\":0,\"exe_path\":\"/tmp/old\",\"hostname\":\"oldhost\"}\n");
    try writeLargeHookErrorLog(&sandbox);

    var result = try sandbox.run(&.{ "gc", "--grace-hours", "0", "--prune-before", "9999-01-01" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "gc: refs_pruned=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "objects_pruned=") != null);

    var sessions = try sandbox.run(&.{ "sessions", "--json" }, null);
    defer sessions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), sessions.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, sessions.stdout, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        parsed.value.object.get("data").?.object.get("sessions").?.array.items.len,
    );

    try expectMissing(&sandbox, ".agit/tmp/stale.json");
    try expectMissing(&sandbox, ".agit/tmp/turns/stale.lock");
    try expectExists(&sandbox, ".agit/log/hook-error.log.1");
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

fn writeLargeHookErrorLog(sandbox: *harness.Sandbox) !void {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.agit/log/hook-error.log", .{sandbox.cwd});
    defer std.testing.allocator.free(path);

    var cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(sandbox.io, path, .{ .truncate = true });
    defer file.close(sandbox.io);

    var chunk = [_]u8{'x'} ** 4096;
    var remaining: usize = 10 * 1024 * 1024 + 1;
    while (remaining > 0) {
        const n = @min(remaining, chunk.len);
        try file.writeStreamingAll(sandbox.io, chunk[0..n]);
        remaining -= n;
    }
}

fn expectMissing(sandbox: *harness.Sandbox, rel_path: []const u8) !void {
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.cwd, rel_path });
    defer std.testing.allocator.free(abs_path);
    _ = std.Io.Dir.cwd().statFile(sandbox.io, abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    return error.ExpectedMissingPath;
}

fn expectExists(sandbox: *harness.Sandbox, rel_path: []const u8) !void {
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.cwd, rel_path });
    defer std.testing.allocator.free(abs_path);
    _ = try std.Io.Dir.cwd().statFile(sandbox.io, abs_path, .{});
}

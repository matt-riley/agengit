const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/claude_payloads" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const user_payload = @embedFile("../fixtures/hooks/claude_user_prompt.json");
    const tool_payload = @embedFile("../fixtures/hooks/claude_post_tool_batch.json");
    const stop_payload = @embedFile("../fixtures/hooks/claude_stop.json");

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
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Sessions: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Steps:    1") != null);

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

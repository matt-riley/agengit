const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/copilot_payloads" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const user_payload = @embedFile("../../../src/fixtures/hooks/copilot_user_prompt.json");
    const tool_payload = @embedFile("../../../src/fixtures/hooks/copilot_post_tool_use.json");
    const stop_payload = @embedFile("../../../src/fixtures/hooks/copilot_stop.json");

    var user_res = try sandbox.run(&.{"copilot-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var tool_res = try sandbox.run(&.{"copilot-hook"}, tool_payload);
    defer tool_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), tool_res.exit_code);

    var stop_res = try sandbox.run(&.{"copilot-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    var sessions = try sandbox.run(&.{"sessions"}, null);
    defer sessions.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, sessions.stdout, "copilot") != null);
}

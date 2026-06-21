const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/gemini_payloads" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const tool_payload = @embedFile("../../../src/fixtures/hooks/gemini_after_tool.json");
    const stop_payload = @embedFile("../../../src/fixtures/hooks/gemini_after_agent.json");

    var tool_res = try sandbox.run(&.{"gemini-hook"}, tool_payload);
    defer tool_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), tool_res.exit_code);

    var stop_res = try sandbox.run(&.{"gemini-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    var status = try sandbox.run(&.{"status"}, null);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Sessions:        1") != null);
}

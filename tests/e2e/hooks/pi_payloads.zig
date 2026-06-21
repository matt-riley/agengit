const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/pi_payloads" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const input_payload = @embedFile("../../../src/fixtures/hooks/pi_input.json");
    const tool_payload = @embedFile("../../../src/fixtures/hooks/pi_tool_execution_end.json");
    const end_payload = @embedFile("../../../src/fixtures/hooks/pi_agent_end.json");

    var input_res = try sandbox.run(&.{"pi-hook"}, input_payload);
    defer input_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), input_res.exit_code);

    var tool_res = try sandbox.run(&.{"pi-hook"}, tool_payload);
    defer tool_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), tool_res.exit_code);

    var end_res = try sandbox.run(&.{"pi-hook"}, end_payload);
    defer end_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), end_res.exit_code);

    var sessions = try sandbox.run(&.{"sessions"}, null);
    defer sessions.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, sessions.stdout, "pi") != null);
}

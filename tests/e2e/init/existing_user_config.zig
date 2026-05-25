const std = @import("std");
const harness = @import("../support/harness.zig");

test "init/existing_user_config" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.createFakeAgent("claude");
    try sandbox.createFakeAgent("codex");
    try sandbox.createFakeAgent("gemini");

    try sandbox.writeHomeFile(".claude/settings.json", "{\n  \"custom\": true,\n  \"hooks\": {\n    \"LocalOnly\": []\n  }\n}\n");

    var first = try sandbox.run(&.{"init"}, null);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);

    const bak_abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/.claude/settings.json.agit.bak", .{sandbox.home});
    defer std.testing.allocator.free(bak_abs);
    const bak = try std.Io.Dir.cwd().readFileAlloc(sandbox.io, bak_abs, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bak);
    try std.testing.expect(std.mem.indexOf(u8, bak, "\"custom\": true") != null);

    const config_abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/.claude/settings.json", .{sandbox.home});
    defer std.testing.allocator.free(config_abs);
    const first_config = try std.Io.Dir.cwd().readFileAlloc(sandbox.io, config_abs, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(first_config);
    try std.testing.expect(std.mem.indexOf(u8, first_config, "\"custom\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_config, "\"LocalOnly\"") != null);

    var second = try sandbox.run(&.{"init"}, null);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
}

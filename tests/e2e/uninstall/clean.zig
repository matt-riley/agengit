const std = @import("std");
const harness = @import("../support/harness.zig");

test "uninstall/clean" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.createFakeAgent("claude");
    try sandbox.createFakeAgent("codex");
    try sandbox.createFakeAgent("gemini");
    try sandbox.createFakeAgent("copilot");
    try sandbox.createFakeAgent("pi");

    var init_result = try sandbox.run(&.{"init"}, null);
    defer init_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), init_result.exit_code);

    try sandbox.writeHomeFile(".claude/settings.json", "{\n  \"hooks\": {\n    \"Stop\": []\n  },\n  \"custom\": \"keep\"\n}\n");
    var reinit = try sandbox.run(&.{"init"}, null);
    defer reinit.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), reinit.exit_code);

    var result = try sandbox.run(&.{"uninstall"}, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const claude = try readHome(&sandbox, ".claude/settings.json");
    defer std.testing.allocator.free(claude);
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"_agit\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, claude, "\"custom\": \"keep\"") != null);

    const copilot_ext = try readHomeOptional(&sandbox, ".copilot/extensions/agit-recorder/extension.mjs");
    defer if (copilot_ext) |text| std.testing.allocator.free(text);
    try std.testing.expect(copilot_ext == null);

    const pi_ext = try readHomeOptional(&sandbox, ".pi/agent/extensions/agit-recorder.js");
    defer if (pi_ext) |text| std.testing.allocator.free(text);
    try std.testing.expect(pi_ext == null);
}

fn readHome(sandbox: *harness.Sandbox, rel_path: []const u8) ![]u8 {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.home, rel_path });
    defer std.testing.allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited);
}

fn readHomeOptional(sandbox: *harness.Sandbox, rel_path: []const u8) !?[]u8 {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.home, rel_path });
    defer std.testing.allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

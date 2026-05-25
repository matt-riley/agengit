const std = @import("std");
const harness = @import("../support/harness.zig");

test "init/fresh" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.createFakeAgent("claude");
    try sandbox.createFakeAgent("codex");
    try sandbox.createFakeAgent("gemini");

    var result = try sandbox.run(&.{"init"}, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try expectContains(result.stdout, "wrote Claude Code hooks");
    try expectContains(result.stdout, "wrote Codex CLI hooks");
    try expectContains(result.stdout, "wrote Gemini CLI hooks");

    const claude = try readHomeConfig(&sandbox, ".claude/settings.json");
    defer std.testing.allocator.free(claude);
    const codex = try readHomeConfig(&sandbox, ".codex/hooks.json");
    defer std.testing.allocator.free(codex);
    const gemini = try readHomeConfig(&sandbox, ".gemini/settings.json");
    defer std.testing.allocator.free(gemini);

    try expectContains(claude, "\"UserPromptSubmit\"");
    try expectContains(claude, "\"PostToolBatch\"");
    try expectContains(claude, "\"Stop\"");
    try expectContains(codex, "\"PostToolUse\"");
    try expectContains(codex, "\"Stop\"");
    try expectContains(gemini, "\"AfterTool\"");
    try expectContains(gemini, "\"AfterAgent\"");
}

fn readHomeConfig(sandbox: *harness.Sandbox, rel_path: []const u8) ![]u8 {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.home, rel_path });
    defer std.testing.allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

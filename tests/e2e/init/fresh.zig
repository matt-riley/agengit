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
    try expectCodexEventShape(codex, "UserPromptSubmit");
    try expectCodexEventShape(codex, "PostToolUse");
    try expectCodexEventShape(codex, "Stop");
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

fn expectCodexEventShape(config: []const u8, event_name: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, config, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks") orelse return error.MissingHooks;
    const event = hooks.object.get(event_name) orelse return error.MissingCodexEvent;
    try std.testing.expect(event == .array);
    try std.testing.expectEqual(@as(usize, 1), event.array.items.len);

    const group = event.array.items[0];
    try std.testing.expect(group == .object);
    const handlers = group.object.get("hooks") orelse return error.MissingCodexHandlers;
    try std.testing.expect(handlers == .array);
    try std.testing.expectEqual(@as(usize, 1), handlers.array.items.len);

    const handler = handlers.array.items[0];
    try std.testing.expect(handler == .object);
    try std.testing.expectEqualStrings("command", handler.object.get("type").?.string);
    try std.testing.expect(std.mem.indexOf(u8, handler.object.get("command").?.string, " codex-hook") != null);
}

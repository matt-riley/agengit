const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/payload_diagnostics malformed payloads stay fail-open with offsets" {
    try expectMalformed("claude-hook", &.{ "claude-hook", "user" });
    try expectMalformed("codex-hook", &.{"codex-hook"});
    try expectMalformed("gemini-hook", &.{"gemini-hook"});
}

fn expectMalformed(expected_agent: []const u8, argv: []const []const u8) !void {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");

    const malformed =
        \\{"session_id":"sess-1","hook_event_name":"UserPromptSubmit","cwd":"/repo","prompt":"hi","authorization":"Bearer secret-token",
    ;

    var result = try sandbox.run(argv, malformed);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, expected_agent) != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "byte offset") != null);

    const log = try sandbox.readRepoFileAlloc(".agit/log/hook-error.log");
    defer std.testing.allocator.free(log);
    const last_line = lastNonEmptyLine(log) orelse return error.TestUnexpectedResult;

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, last_line, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const root = parsed.value.object;
    try std.testing.expectEqualStrings(expected_agent, root.get("agent").?.string);
    try std.testing.expect(root.get("parse_offset") != null);
    try std.testing.expect(root.get("payload_snippet") != null);
    try std.testing.expect(std.mem.indexOf(u8, root.get("payload_snippet").?.string, "secret-token") == null);
}

fn lastNonEmptyLine(content: []const u8) ?[]const u8 {
    var end = content.len;
    while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r' or content[end - 1] == ' ' or content[end - 1] == '\t')) : (end -= 1) {}
    if (end == 0) return null;
    const start = std.mem.lastIndexOfScalar(u8, content[0..end], '\n') orelse 0;
    const line = if (start == 0) content[0..end] else content[start + 1 .. end];
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return if (trimmed.len == 0) null else trimmed;
}

const std = @import("std");
const harness = @import("../support/harness.zig");

test "analytics/diff supports step, cross-step, session, and json forms" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try seedAnalyticsSession(&sandbox);
    const hashes = try sessionStepHashes(&sandbox, "codex/analytics-sess");
    defer freeStrings(hashes);
    try std.testing.expectEqual(@as(usize, 2), hashes.len);

    var single = try sandbox.run(&.{ "diff", hashes[0] }, null);
    defer single.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), single.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, single.stdout, "diff --git a/a.txt b/a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, single.stdout, "+alpha") != null);

    var cross = try sandbox.run(&.{ "diff", hashes[0], hashes[1], "--", "a.txt" }, null);
    defer cross.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), cross.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, cross.stdout, "+beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, cross.stdout, "b.txt") == null);

    var session = try sandbox.run(&.{ "diff", "--session", "codex/analytics-sess" }, null);
    defer session.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), session.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, session.stdout, "+alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.stdout, "+beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.stdout, "diff --git a/b.txt b/b.txt") != null);

    var json = try sandbox.run(&.{ "diff", "--json", hashes[0], hashes[1] }, null);
    defer json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), json.exit_code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("diff", parsed.value.object.get("command").?.string);
    try std.testing.expectEqualStrings("step_tree", data.get("baseline").?.string);
    try std.testing.expect(data.get("changes").?.array.items.len >= 2);
}

test "analytics/stats summarizes repository and session activity" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try seedAnalyticsSession(&sandbox);

    var stats = try sandbox.run(&.{"stats"}, null);
    defer stats.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stats.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stats.stdout, "Sessions: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats.stdout, "Steps: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats.stdout, "bash: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats.stdout, "a.txt: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, stats.stdout, "b.txt: 1") != null);

    var scoped = try sandbox.run(&.{ "stats", "--session", "codex/analytics-sess" }, null);
    defer scoped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), scoped.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, scoped.stdout, "Scope: codex/analytics-sess") != null);

    var json = try sandbox.run(&.{ "stats", "--json", "--session", "codex/analytics-sess" }, null);
    defer json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), json.exit_code);
    var parsed = try parseJson(json.stdout);
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqualStrings("stats", parsed.value.object.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 1), data.get("summary").?.object.get("session_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), data.get("summary").?.object.get("step_count").?.integer);
    try std.testing.expect(data.get("tool_calls").?.array.items.len >= 1);
    try std.testing.expect(data.get("most_changed_paths").?.array.items.len >= 2);
}

fn seedAnalyticsSession(sandbox: *harness.Sandbox) !void {
    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("a.txt", "alpha\n");
    try recordTurn(sandbox, "analytics-sess", "turn-a", "create a", "bash", "seeded");
    try sandbox.writeRepoFile("a.txt", "alpha\nbeta\n");
    try sandbox.writeRepoFile("b.txt", "bravo\n");
    try recordTurn(sandbox, "analytics-sess", "turn-b", "extend a and add b", "bash", "updated");
}

fn recordTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    tool_name: []const u8,
    assistant: []const u8,
) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, prompt });
    defer std.testing.allocator.free(user_payload);
    const tool_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"PostToolUse","tool_name":"{s}","tool_input":{{"command":"true"}},"tool_response":"ok"}}
    , .{ session_id, turn_id, sandbox.cwd, tool_name });
    defer std.testing.allocator.free(tool_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, assistant });
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{"codex-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var tool_res = try sandbox.run(&.{"codex-hook"}, tool_payload);
    defer tool_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), tool_res.exit_code);

    var stop_res = try sandbox.run(&.{"codex-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);
}

fn sessionStepHashes(sandbox: *harness.Sandbox, session: []const u8) ![][]u8 {
    var log = try sandbox.run(&.{ "log", "--json", session }, null);
    defer log.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log.exit_code);
    var parsed = try parseJson(log.stdout);
    defer parsed.deinit();
    const steps = parsed.value.object.get("data").?.object.get("steps").?.array.items;
    const out = try std.testing.allocator.alloc([]u8, steps.len);
    errdefer std.testing.allocator.free(out);
    for (steps, 0..) |step, i| {
        out[i] = try std.testing.allocator.dupe(u8, step.object.get("hash").?.string);
    }
    return out;
}

fn freeStrings(values: [][]u8) void {
    for (values) |value| std.testing.allocator.free(value);
    std.testing.allocator.free(values);
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

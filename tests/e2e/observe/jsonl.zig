const std = @import("std");
const harness = @import("../support/harness.zig");

// Covers the three properties that prove the jsonl source + framework work
// end to end: one-pass recording, resume without duplicates, and append-new.

fn oneTurn(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\{{"session_id":"observer-session","cwd":"{s}","role":"user","content":"first prompt"}}
        \\{{"session_id":"observer-session","cwd":"{s}","role":"tool","tool_name":"bash","args":"echo first","result":"first-result"}}
        \\{{"session_id":"observer-session","cwd":"{s}","role":"assistant","content":"assistant one"}}
        \\
    , .{ cwd, cwd, cwd });
}

fn twoTurns(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\{{"session_id":"observer-session","cwd":"{s}","role":"user","content":"first prompt"}}
        \\{{"session_id":"observer-session","cwd":"{s}","role":"tool","tool_name":"bash","args":"echo first","result":"first-result"}}
        \\{{"session_id":"observer-session","cwd":"{s}","role":"assistant","content":"assistant one"}}
        \\{{"session_id":"observer-session","cwd":"{s}","role":"user","content":"second prompt"}}
        \\{{"session_id":"observer-session","cwd":"{s}","role":"tool","tool_name":"bash","args":"echo second","result":"second-result"}}
        \\{{"session_id":"observer-session","cwd":"{s}","role":"assistant","content":"assistant two"}}
        \\
    , .{ cwd, cwd, cwd, cwd, cwd, cwd });
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

test "observe/jsonl_once_resume_append" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");

    // 1. One pass: 3 events -> 1 finalized turn.
    const first_log = try oneTurn(std.testing.allocator, sandbox.cwd);
    defer std.testing.allocator.free(first_log);
    try sandbox.writeRepoFile("session.jsonl", first_log);

    var first = try sandbox.run(&.{ "observe", "--once", "jsonl", "--input", "session.jsonl" }, null);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), first.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, first.stdout, "processed 3 event(s)") != null);

    var status_after_first = try sandbox.run(&.{"status"}, null);
    defer status_after_first.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_after_first.stdout, "Steps:           1") != null);

    // 2. Re-run with no new content: zero new events (checkpoint dedup).
    var second = try sandbox.run(&.{ "observe", "--once", "jsonl", "--input", "session.jsonl" }, null);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), second.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, second.stdout, "processed 0 event(s)") != null);

    var status_after_second = try sandbox.run(&.{"status"}, null);
    defer status_after_second.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_after_second.stdout, "Steps:           1") != null);

    // 3. Append new lines (rewrite with 6 lines): only the 3 new events recorded.
    const appended_log = try twoTurns(std.testing.allocator, sandbox.cwd);
    defer std.testing.allocator.free(appended_log);
    try sandbox.writeRepoFile("session.jsonl", appended_log);

    var third = try sandbox.run(&.{ "observe", "--once", "jsonl", "--input", "session.jsonl" }, null);
    defer third.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), third.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, third.stdout, "processed 3 event(s)") != null);

    var status_after_third = try sandbox.run(&.{"status"}, null);
    defer status_after_third.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_after_third.stdout, "Sessions:        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_after_third.stdout, "Steps:           2") != null);

    // 4. The recorded session has both turns persisted.
    var log_result = try sandbox.run(&.{ "log", "--json", "jsonl/observer-session" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    var parsed_log = try parseJson(log_result.stdout);
    defer parsed_log.deinit();
    const steps = parsed_log.value.object.get("data").?.object.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
}

test "observe/jsonl_publishes_assistant_content" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");

    const log = try oneTurn(std.testing.allocator, sandbox.cwd);
    defer std.testing.allocator.free(log);
    try sandbox.writeRepoFile("session.jsonl", log);

    var observe = try sandbox.run(&.{ "observe", "--once", "jsonl", "--input", "session.jsonl" }, null);
    defer observe.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), observe.exit_code);

    var log_result = try sandbox.run(&.{ "log", "--json" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    var parsed_log = try parseJson(log_result.stdout);
    defer parsed_log.deinit();
    const steps = parsed_log.value.object.get("data").?.object.get("steps").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    const step_hash = try std.testing.allocator.dupe(u8, steps[0].object.get("hash").?.string);
    defer std.testing.allocator.free(step_hash);

    var show_result = try sandbox.run(&.{ "show", "--json", step_hash }, null);
    defer show_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), show_result.exit_code);
    var parsed = try parseJson(show_result.stdout);
    defer parsed.deinit();
    const messages = parsed.value.object.get("data").?.object.get("step").?.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("user", messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("first prompt", messages[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", messages[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("assistant one", messages[1].object.get("content").?.string);
}

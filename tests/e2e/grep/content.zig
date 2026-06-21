const std = @import("std");
const harness = @import("../support/harness.zig");

test "grep/content finds text in captured workspace files" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    // Write a file that our session will capture via snapshot
    try sandbox.writeRepoFile("src/utils.zig", "pub fn calculateFactorial(n: u32) u32 {\n    return if (n <= 1) 1 else n * calculateFactorial(n - 1);\n}\n");
    try sandbox.writeRepoFile(".agit/.keep", "");

    try seedContentSession(&sandbox);

    var today_buf: [10]u8 = undefined;
    const today = try currentUtcDate(&today_buf);

    // Search for a term that exists in the captured file
    var result = try sandbox.run(&.{
        "grep",
        "--content",
        "--origin",
        "claude",
        "--since",
        today,
        "--until",
        today,
        "calculateFactorial",
    }, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "calculateFactorial") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "src/utils.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "content") != null);

    // Search for a term that does NOT exist
    var missing = try sandbox.run(&.{
        "grep",
        "--content",
        "--origin",
        "claude",
        "--since",
        today,
        "--until",
        today,
        "nonexistent12345",
    }, null);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), missing.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, missing.stdout, "No content matches") != null);
}

test "grep/content redacts secret patterns in blob content" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    // Write a file containing a secret-like pattern
    try sandbox.writeRepoFile("src/config.zig", "const api_token = \"ghp_1234567890abcdefghij\";\n");
    try sandbox.writeRepoFile(".agit/.keep", "");

    try seedContentSession(&sandbox);

    var today_buf: [10]u8 = undefined;
    const today = try currentUtcDate(&today_buf);

    // Search with default redaction (auto mode, repo default is no redaction by default)
    // Use --redacted to force redaction
    var result = try sandbox.run(&.{
        "grep",
        "--content",
        "--redacted",
        "--origin",
        "claude",
        "--since",
        today,
        "--until",
        today,
        "ghp_1234567890abcdefghij",
    }, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // The token should be redacted in output
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "[REDACTED]") != null);
    // But the path should be visible
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "src/config.zig") != null);
}

test "grep/content metadata-only capture yields no content matches" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    // Write a file with known content
    try sandbox.writeRepoFile("src/secret.txt", "this is secret content 12345\n");
    try sandbox.writeRepoFile(".agit/.keep", "");

    // Configure capture to metadata-only
    const config_json =
        \\{"privacy":{"capture":{"snapshots":"metadata_only"}}}
    ;
    try sandbox.writeRepoFile(".agit/config.json", config_json);

    try seedContentSession(&sandbox);

    var today_buf: [10]u8 = undefined;
    const today = try currentUtcDate(&today_buf);

    // Search for a term that exists in the file - should not be found because
    // the captured blob is a metadata-only placeholder, not the real content.
    var result = try sandbox.run(&.{
        "grep",
        "--content",
        "--origin",
        "claude",
        "--since",
        today,
        "--until",
        today,
        "secret",
    }, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    // Should report no matches because placeholder blobs are skipped.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "No content matches") != null);
}

fn seedContentSession(sandbox: *harness.Sandbox) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"Write a utility function"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{ "claude-hook", "user" }, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{ "claude-hook", "assistant" }, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);
}

fn currentUtcDate(buf: *[10]u8) ![]const u8 {
    const now = std.Io.Timestamp.now(std.testing.io, .real);
    const secs: u64 = @intCast(@divTrunc(now.toMilliseconds(), 1000));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const eday = es.getEpochDay();
    const yd = eday.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
    });
}

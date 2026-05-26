const std = @import("std");
const harness = @import("../support/harness.zig");

test "privacy/scan finds secrets without echoing them and show redacts on demand" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"scan-sess","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"Authorization: Bearer secret-token-123456"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"scan-sess","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{ "claude-hook", "user" }, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{ "claude-hook", "assistant" }, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    var scan_result = try sandbox.run(&.{ "privacy", "scan" }, null);
    defer scan_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), scan_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, scan_result.stdout, "bearer_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan_result.stdout, "secret-token-123456") == null);

    var scan_json = try sandbox.run(&.{ "privacy", "scan", "--json" }, null);
    defer scan_json.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), scan_json.exit_code);
    var parsed_scan = try parseJson(scan_json.stdout);
    defer parsed_scan.deinit();
    try std.testing.expect(!parsed_scan.value.object.get("data").?.object.get("clean").?.bool);

    var log_result = try sandbox.run(&.{ "log", "--json" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    const step_hash = try extractFirstStepHash(log_result.stdout);
    defer std.testing.allocator.free(step_hash);

    var show_result = try sandbox.run(&.{ "show", "--json", "--redacted", step_hash }, null);
    defer show_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), show_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, show_result.stdout, "secret-token-123456") == null);
    try std.testing.expect(std.mem.indexOf(u8, show_result.stdout, "[REDACTED]") != null);
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

fn extractFirstStepHash(data: []const u8) ![]const u8 {
    var parsed = try parseJson(data);
    defer parsed.deinit();
    const steps = parsed.value.object.get("data").?.object.get("steps").?.array.items;
    return try std.testing.allocator.dupe(u8, steps[0].object.get("hash").?.string);
}

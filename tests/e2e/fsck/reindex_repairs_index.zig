const std = @import("std");
const zqlite = @import("zqlite");
const harness = @import("../support/harness.zig");

test "fsck/reindex_repairs_index" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try seedClaudeSession(&sandbox);
    try deleteIndexedSteps(&sandbox);

    var before = try sandbox.run(&.{ "fsck", "--json" }, null);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), before.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, before.stdout, "\"code\":\"index_steps_drift\"") != null);

    var repaired = try sandbox.run(&.{ "fsck", "--reindex", "--json" }, null);
    defer repaired.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), repaired.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, repaired.stdout, "\"code\":\"index_ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, repaired.stdout, "\"repair\":{\"sessions\":1,\"steps\":1}") != null);
}

fn deleteIndexedSteps(sandbox: *harness.Sandbox) !void {
    const index_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.agit/index.db", .{sandbox.cwd});
    defer std.testing.allocator.free(index_path);
    const index_path_z = try std.testing.allocator.dupeZ(u8, index_path);
    defer std.testing.allocator.free(index_path_z);

    const db = try zqlite.open(index_path_z, zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode);
    defer db.close();
    try db.busyTimeout(5_000);
    try db.execNoArgs("delete from steps");
}

fn seedClaudeSession(sandbox: *harness.Sandbox) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"Write a function to calculate factorial"}}
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

const std = @import("std");
const harness = @import("../support/harness.zig");

test "hooks/repeated_turns_same_session_record_distinct_steps" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");

    const session_id = "codex-sess-repeat";

    const user1 = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"first prompt"}}
    , .{ session_id, sandbox.cwd });
    defer std.testing.allocator.free(user1);
    const tool1 = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","cwd":"{s}","hook_event_name":"PostToolUse","tool_name":"bash","tool_input":{{"command":"echo first"}},"tool_use_id":"tool-1","tool_response":"first"}}
    , .{ session_id, sandbox.cwd });
    defer std.testing.allocator.free(tool1);
    const stop1 = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"assistant one"}}
    , .{ session_id, sandbox.cwd });
    defer std.testing.allocator.free(stop1);

    const user2 = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"second prompt"}}
    , .{ session_id, sandbox.cwd });
    defer std.testing.allocator.free(user2);
    const tool2 = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","cwd":"{s}","hook_event_name":"PostToolUse","tool_name":"bash","tool_input":{{"command":"echo second"}},"tool_use_id":"tool-2","tool_response":"second"}}
    , .{ session_id, sandbox.cwd });
    defer std.testing.allocator.free(tool2);
    const stop2 = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"assistant two"}}
    , .{ session_id, sandbox.cwd });
    defer std.testing.allocator.free(stop2);

    var r1 = try sandbox.run(&.{"codex-hook"}, user1);
    defer r1.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), r1.exit_code);
    var r2 = try sandbox.run(&.{"codex-hook"}, tool1);
    defer r2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), r2.exit_code);
    var r3 = try sandbox.run(&.{"codex-hook"}, stop1);
    defer r3.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), r3.exit_code);

    var r4 = try sandbox.run(&.{"codex-hook"}, user2);
    defer r4.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), r4.exit_code);
    var r5 = try sandbox.run(&.{"codex-hook"}, tool2);
    defer r5.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), r5.exit_code);
    var r6 = try sandbox.run(&.{"codex-hook"}, stop2);
    defer r6.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), r6.exit_code);

    var status = try sandbox.run(&.{"status"}, null);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Sessions:        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Steps:           2") != null);

    const scoped_session = try std.fmt.allocPrint(std.testing.allocator, "codex/{s}", .{session_id});
    defer std.testing.allocator.free(scoped_session);
    var log = try sandbox.run(&.{ "log", scoped_session }, null);
    defer log.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log.exit_code);
}

test "hooks/payload_cwd_wins_when_process_cwd_differs" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");

    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"codex-cwd-diff","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"cwd fallback check"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"codex-cwd-diff","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var user = try sandbox.runFromCwd(sandbox.home, &.{"codex-hook"}, user_payload);
    defer user.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user.exit_code);

    var stop = try sandbox.runFromCwd(sandbox.home, &.{"codex-hook"}, stop_payload);
    defer stop.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop.exit_code);

    var status = try sandbox.run(&.{"status"}, null);
    defer status.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Sessions:        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.stdout, "Steps:           1") != null);
}

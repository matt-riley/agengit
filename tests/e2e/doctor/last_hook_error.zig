const std = @import("std");
const harness = @import("../support/harness.zig");

test "doctor/last_hook_error pretty prints latest hook error" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();
    try sandbox.writeRepoFile(".agit/.keep", "");

    const malformed =
        \\{"session_id":"sess-2","hook_event_name":"UserPromptSubmit","cwd":"/repo","prompt":"hi",
    ;
    var hook_res = try sandbox.run(&.{ "claude-hook", "user" }, malformed);
    defer hook_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), hook_res.exit_code);

    var doctor_res = try sandbox.run(&.{ "doctor", "--last-hook-error" }, null);
    defer doctor_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), doctor_res.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, doctor_res.stdout, "\"agent\": \"claude-hook\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doctor_res.stdout, "\"parse_offset\"") != null);
}

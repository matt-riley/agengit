const std = @import("std");
const harness = @import("../support/harness.zig");

test "doctor/drifted_store" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"session_id\":\"drift-sess\",\"cwd\":\"{s}\",\"hook_event_name\":\"AfterAgent\",\"response\":\"ok\"}}",
        .{sandbox.cwd},
    );
    defer std.testing.allocator.free(payload);
    var hook = try sandbox.run(&.{"gemini-hook"}, payload);
    defer hook.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), hook.exit_code);

    const origin_hex = std.fmt.bytesToHex("gemini", .lower);
    const session_hex = std.fmt.bytesToHex("drift-sess", .lower);
    const ref_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".agit/refs/sessions/{s}/{s}",
        .{ &origin_hex, &session_hex },
    );
    defer std.testing.allocator.free(ref_path);
    try sandbox.writeRepoFile(ref_path, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\n");

    var result = try sandbox.run(&.{"doctor"}, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.exit_code != 0);
    const has_drift = std.mem.indexOf(u8, result.stdout, "ref/index drift:") != null;
    const has_store_error = std.mem.indexOf(u8, result.stdout, ".agit/ store:") != null;
    try std.testing.expect(has_drift or has_store_error);
}

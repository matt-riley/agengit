const std = @import("std");
const harness = @import("../support/harness.zig");

test "doctor/config_tmp_files" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeHomeFile(".claude/settings.json.agit-tmp-123", "{\"partial\":true}\n");

    var result = try sandbox.run(&.{"doctor"}, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "crash-temp file") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "settings.json.agit-tmp-") != null);
}

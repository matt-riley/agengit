const std = @import("std");
const harness = @import("support/harness.zig");
const golden = @import("support/golden.zig");

test "golden/help" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{"--help"}, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help.txt", result.stdout);
}

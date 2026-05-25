const std = @import("std");
const harness = @import("../support/harness.zig");
const golden = @import("../support/golden.zig");

test "doctor/healthy_store" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    var result = try sandbox.run(&.{"doctor"}, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/doctor_healthy.txt", result.stdout);
}

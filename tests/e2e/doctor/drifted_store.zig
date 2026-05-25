const std = @import("std");
const harness = @import("../support/harness.zig");

test "doctor/drifted_store" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile(".agit/tmp/bad.json", "{not-json");

    var result = try sandbox.run(&.{"doctor"}, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".agit/tmp staging:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "corrupt") != null);
}

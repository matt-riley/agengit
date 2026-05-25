const std = @import("std");
const harness = @import("../support/harness.zig");

test "doctor/locks" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile(
        ".agit/tmp/held.json.lock",
        "{\"pid\":12345,\"started_at\":0,\"exe_path\":\"/tmp/fake-agit\",\"hostname\":\"localhost\"}\n",
    );

    var result = try sandbox.run(&.{ "doctor", "--locks" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tmp/held.json.lock") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "exe=/tmp/fake-agit") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "age_ms=") != null);
}

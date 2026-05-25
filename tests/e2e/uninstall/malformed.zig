const std = @import("std");
const harness = @import("../support/harness.zig");

test "uninstall/malformed" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.createFakeAgent("claude");
    try sandbox.writeHomeFile(".claude/settings.json", "{not-json");

    var result = try sandbox.run(&.{"uninstall"}, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    const config = try readHome(&sandbox, ".claude/settings.json");
    defer std.testing.allocator.free(config);
    try std.testing.expectEqualStrings("{not-json", config);
}

fn readHome(sandbox: *harness.Sandbox, rel_path: []const u8) ![]u8 {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.home, rel_path });
    defer std.testing.allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited);
}

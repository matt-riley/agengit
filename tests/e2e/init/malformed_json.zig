const std = @import("std");
const harness = @import("../support/harness.zig");

test "init/malformed_json" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.createFakeAgent("claude");
    try sandbox.writeHomeFile(".claude/settings.json", "{not-json");

    var result = try sandbox.run(&.{"init"}, null);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, ".claude/settings.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "offset=") != null);

    const config = try readHome(&sandbox, ".claude/settings.json");
    defer std.testing.allocator.free(config);
    try std.testing.expectEqualStrings("{not-json", config);
}

fn readHome(sandbox: *harness.Sandbox, rel_path: []const u8) ![]u8 {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.home, rel_path });
    defer std.testing.allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited);
}

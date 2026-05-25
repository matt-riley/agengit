const std = @import("std");
const harness = @import("support/harness.zig");
const golden = @import("support/golden.zig");

test "golden/completion/bash" {
    try assertCompletionGolden("bash", "tests/golden/completion/bash.txt");
}

test "golden/completion/zsh" {
    try assertCompletionGolden("zsh", "tests/golden/completion/zsh.txt");
}

test "golden/completion/fish" {
    try assertCompletionGolden("fish", "tests/golden/completion/fish.txt");
}

test "golden/completion/nushell" {
    try assertCompletionGolden("nushell", "tests/golden/completion/nushell.txt");
}

fn assertCompletionGolden(shell: []const u8, rel_path: []const u8) !void {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "completion", shell }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, rel_path, result.stdout);
}

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

test "golden/help/status" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "status", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/status.txt", result.stdout);
}

test "golden/help/sessions" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "sessions", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/sessions.txt", result.stdout);
}

test "golden/help/log" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "log", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/log.txt", result.stdout);
}

test "golden/help/show" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "show", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/show.txt", result.stdout);
}

test "golden/help/blame" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "blame", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/blame.txt", result.stdout);
}

test "golden/help/cat" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "cat", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/cat.txt", result.stdout);
}

test "golden/help/completion" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "completion", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/completion.txt", result.stdout);
}

test "golden/help/init" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "init", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/init.txt", result.stdout);
}

test "golden/help/uninstall" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "uninstall", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/uninstall.txt", result.stdout);
}

test "golden/help/doctor" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "doctor", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/doctor.txt", result.stdout);
}

test "golden/help/reindex" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "reindex", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/reindex.txt", result.stdout);
}

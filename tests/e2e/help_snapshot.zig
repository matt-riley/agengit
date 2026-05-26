const std = @import("std");
const harness = @import("support/harness.zig");
const golden = @import("support/golden.zig");
const docgen = @import("cli_docgen");

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

test "golden/help/version" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var result = try sandbox.run(&.{ "version", "--help" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    try golden.assertGolden(&sandbox, "tests/golden/help/version.txt", result.stdout);
}

test "readme command synopses match command help" {
    const gpa = std.testing.allocator;
    var sandbox = try harness.Sandbox.init(gpa);
    defer sandbox.deinit();

    const readme_text = try readRepoReadmeAlloc(gpa, sandbox.agit_bin);
    defer gpa.free(readme_text);

    var readme_synopses = try docgen.collectReadmeSynopses(gpa, readme_text);
    defer deinitSynopses(gpa, &readme_synopses);

    try std.testing.expectEqual(docgen.public_commands.len, readme_synopses.count());

    for (docgen.public_commands) |command| {
        var result = try sandbox.run(&.{ command.name, "--help" }, null);
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), result.exit_code);

        const usage_line = try extractUsageLine(result.stdout);
        const readme_synopsis = readme_synopses.get(command.name) orelse return error.MissingSynopsis;
        try std.testing.expectEqualStrings(readme_synopsis, usage_line);
    }
}

fn extractUsageLine(help_text: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, help_text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (!std.mem.eql(u8, line, "USAGE:")) continue;
        while (lines.next()) |raw_usage| {
            const usage = std.mem.trim(u8, raw_usage, " \t\r");
            if (usage.len == 0) continue;
            return usage;
        }
        break;
    }
    return error.MissingUsageLine;
}

fn deinitSynopses(gpa: std.mem.Allocator, synopses: *docgen.SynopsisMap) void {
    var iter = synopses.iterator();
    while (iter.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        gpa.free(entry.value_ptr.*);
    }
    synopses.deinit();
}

fn readRepoReadmeAlloc(gpa: std.mem.Allocator, agit_bin: []const u8) ![]u8 {
    const repo_root = deriveRepoRoot(agit_bin) orelse return error.FileNotFound;
    const readme_path = try std.fmt.allocPrint(gpa, "{s}/README.md", .{repo_root});
    defer gpa.free(readme_path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, readme_path, gpa, .unlimited);
}

fn deriveRepoRoot(agit_bin: []const u8) ?[]const u8 {
    const bin_dir = std.fs.path.dirname(agit_bin) orelse return null;
    const zig_out_dir = std.fs.path.dirname(bin_dir) orelse return null;
    return std.fs.path.dirname(zig_out_dir);
}

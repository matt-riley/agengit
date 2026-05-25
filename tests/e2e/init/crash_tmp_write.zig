const std = @import("std");
const harness = @import("../support/harness.zig");

test "init/crash_tmp_write" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.createFakeAgent("claude");
    try sandbox.writeHomeFile(
        ".claude/settings.json",
        "{\n  \"custom\": true,\n  \"hooks\": {\n    \"LocalOnly\": []\n  }\n}\n",
    );
    const before = try readHome(&sandbox, ".claude/settings.json");
    defer std.testing.allocator.free(before);

    var result = try sandbox.runWithEnv(&.{"init"}, null, &.{"AGIT_CRASH_AFTER=tmp_write"});
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.exit_code != 0);

    const after = try readHome(&sandbox, ".claude/settings.json");
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);

    try std.testing.expect(try hasCrashTempFile(&sandbox, ".claude", "settings.json.agit-tmp-"));
}

fn hasCrashTempFile(sandbox: *harness.Sandbox, rel_dir: []const u8, prefix: []const u8) !bool {
    const abs_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.home, rel_dir });
    defer std.testing.allocator.free(abs_dir);

    var dir = std.Io.Dir.cwd().openDir(sandbox.io, abs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer dir.close(sandbox.io);

    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(sandbox.io)) |entry| {
        if (entry.kind != .file) continue;
        const base = std.fs.path.basename(entry.path);
        if (std.mem.startsWith(u8, base, prefix)) return true;
    }
    return false;
}

fn readHome(sandbox: *harness.Sandbox, rel_path: []const u8) ![]u8 {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.home, rel_path });
    defer std.testing.allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited);
}

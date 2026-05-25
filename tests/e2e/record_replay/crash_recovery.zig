const std = @import("std");
const harness = @import("../support/harness.zig");

test "record_replay/crash_recovery" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const user_payload =
        \\{"session_id":"crash-recovery-001","cwd":"/repo","hook_event_name":"UserPromptSubmit","prompt":"hello"}
    ;
    var user_res = try sandbox.run(&.{"codex-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    const staging_path = try findStagingFile(&sandbox);
    defer std.testing.allocator.free(staging_path);

    var bad = try std.Io.Dir.cwd().createFile(sandbox.io, staging_path, .{ .truncate = true });
    defer bad.close(sandbox.io);
    try bad.writeStreamingAll(sandbox.io, "{not-json");

    const stop_payload =
        \\{"session_id":"crash-recovery-001","cwd":"/repo","hook_event_name":"Stop","last_assistant_message":"done"}
    ;
    var stop_res = try sandbox.run(&.{"codex-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    const log_abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/.agit/log/hook-error.log", .{sandbox.cwd});
    defer std.testing.allocator.free(log_abs);
    const hook_errors = try std.Io.Dir.cwd().readFileAlloc(sandbox.io, log_abs, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(hook_errors);
    try std.testing.expect(std.mem.indexOf(u8, hook_errors, "corrupt_staging") != null);

    try std.testing.expect(try hasCorruptStagingDump(&sandbox));
}

fn findStagingFile(sandbox: *harness.Sandbox) ![]u8 {
    const gpa = std.testing.allocator;
    const io = sandbox.io;
    const tmp_abs = try std.fmt.allocPrint(gpa, "{s}/.agit/tmp", .{sandbox.cwd});
    defer gpa.free(tmp_abs);
    var tmp_dir = try std.Io.Dir.cwd().openDir(io, tmp_abs, .{ .iterate = true });
    defer tmp_dir.close(io);
    var walker = try tmp_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/')) |_| continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;
        if (std.mem.endsWith(u8, entry.path, ".json.lock")) continue;
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ tmp_abs, entry.path });
    }
    return error.FileNotFound;
}

fn hasCorruptStagingDump(sandbox: *harness.Sandbox) !bool {
    const gpa = std.testing.allocator;
    const io = sandbox.io;
    const dump_dir_abs = try std.fmt.allocPrint(gpa, "{s}/.agit/log/corrupt-staging", .{sandbox.cwd});
    defer gpa.free(dump_dir_abs);
    var dump_dir = std.Io.Dir.cwd().openDir(io, dump_dir_abs, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer dump_dir.close(io);
    var walker = try dump_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".json")) return true;
    }
    return false;
}

const std = @import("std");
const harness = @import("../support/harness.zig");

test "record_replay/concurrent_writers" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const io = sandbox.io;
    const gpa = std.testing.allocator;
    const home_env = try std.fmt.allocPrint(gpa, "HOME={s}", .{sandbox.home});
    defer gpa.free(home_env);
    const path_env = try std.fmt.allocPrint(gpa, "PATH={s}:/usr/bin:/bin", .{sandbox.bin});
    defer gpa.free(path_env);
    const lock_timeout_env = "AGIT_LOCK_TIMEOUT_MS=60000";

    var children: [8]std.process.Child = undefined;
    var payloads: [8][]u8 = undefined;
    defer for (payloads) |payload| gpa.free(payload);

    for (0..children.len) |i| {
        payloads[i] = try std.fmt.allocPrint(gpa,
            \\{{"session_id":"gemini-sess-{d}","cwd":"{s}","hook_event_name":"AfterAgent","response":"ok"}}
        , .{ i, sandbox.cwd });
        children[i] = try std.process.spawn(io, .{
            .argv = &.{ "/usr/bin/env", home_env, path_env, lock_timeout_env, sandbox.agit_bin, "gemini-hook" },
            .cwd = .{ .path = sandbox.cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
    }

    for (&children, 0..) |*child, i| {
        try child.stdin.?.writeStreamingAll(io, payloads[i]);
        child.stdin.?.close(io);
        child.stdin = null;
    }

    for (&children) |*child| {
        var stdout_buf: [2048]u8 = undefined;
        var stderr_buf: [2048]u8 = undefined;
        var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
        var stderr_reader = child.stderr.?.reader(io, &stderr_buf);
        const out = try stdout_reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(out);
        const err = try stderr_reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(err);
        child.stdout.?.close(io);
        child.stdout = null;
        child.stderr.?.close(io);
        child.stderr = null;

        const term = try child.wait(io);
        try std.testing.expect(term == .exited and term.exited == 0);
    }

    var status = try sandbox.run(&.{"status"}, null);
    defer status.deinit(gpa);
    const sessions = try parseCount(status.stdout, "Sessions:");
    const steps = try parseCount(status.stdout, "Steps:");
    try std.testing.expect(sessions > 0);
    try std.testing.expect(sessions <= 8);
    try std.testing.expectEqual(sessions, steps);

    var doctor = try sandbox.run(&.{ "doctor", "--stats" }, null);
    defer doctor.deinit(gpa);
    const objects_written = try parseNamedValue(doctor.stdout, "objects_written_total=");
    try std.testing.expectEqual(steps, objects_written);

    const err_log = try readOptional(&sandbox, ".agit/log/hook-error.log");
    defer if (err_log) |buf| gpa.free(buf);
    if (err_log) |buf| {
        try std.testing.expect(std.mem.indexOf(u8, buf, "corrupt_staging") == null);
        try std.testing.expect(std.mem.indexOf(u8, buf, "CorruptRef") == null);
        try std.testing.expect(std.mem.indexOf(u8, buf, "lock_timeout") == null);
        try std.testing.expect(std.mem.indexOf(u8, buf, "LockTimeout") == null);
    }
}

fn readOptional(sandbox: *harness.Sandbox, rel_path: []const u8) !?[]u8 {
    const abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.cwd, rel_path });
    defer std.testing.allocator.free(abs);
    return std.Io.Dir.cwd().readFileAlloc(sandbox.io, abs, std.testing.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn parseCount(output: []const u8, prefix: []const u8) !usize {
    const start = std.mem.indexOf(u8, output, prefix) orelse return error.InvalidFormat;
    const rest = output[start + prefix.len ..];
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == i) return error.InvalidFormat;
    return std.fmt.parseUnsigned(usize, rest[i..end], 10);
}

fn parseNamedValue(output: []const u8, key: []const u8) !usize {
    const start = std.mem.indexOf(u8, output, key) orelse return error.InvalidFormat;
    const rest = output[start + key.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return error.InvalidFormat;
    return std.fmt.parseUnsigned(usize, rest[0..end], 10);
}

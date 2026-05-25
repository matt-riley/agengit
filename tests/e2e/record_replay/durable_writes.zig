const std = @import("std");
const harness = @import("../support/harness.zig");

test "record_replay/durable_writes" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    const user_payload =
        \\{"session_id":"durable-001","cwd":"/repo","hook_event_name":"UserPromptSubmit","prompt":"hello"}
    ;
    var user_res = try sandbox.run(&.{"codex-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    const stop_payload =
        \\{"session_id":"durable-001","cwd":"/repo","hook_event_name":"Stop","last_assistant_message":"done"}
    ;
    var stop_res = try sandbox.run(&.{"codex-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);

    const ref_hash = try readFirstRefHash(&sandbox);
    defer std.testing.allocator.free(ref_hash);

    try expectObjectExists(&sandbox, ref_hash);

    var cat_res = try sandbox.run(&.{ "cat", ref_hash }, null);
    defer cat_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), cat_res.exit_code);
}

fn readFirstRefHash(sandbox: *harness.Sandbox) ![]u8 {
    const gpa = std.testing.allocator;
    const io = sandbox.io;
    const refs_abs = try std.fmt.allocPrint(gpa, "{s}/.agit/refs/sessions", .{sandbox.cwd});
    defer gpa.free(refs_abs);

    var refs_dir = try std.Io.Dir.cwd().openDir(io, refs_abs, .{ .iterate = true });
    defer refs_dir.close(io);

    var walker = try refs_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const abs_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ refs_abs, entry.path });
        defer gpa.free(abs_path);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, abs_path, gpa, .unlimited);
        defer gpa.free(data);
        const trimmed = std.mem.trim(u8, data, " \r\n");
        if (trimmed.len != 64) continue;
        return gpa.dupe(u8, trimmed);
    }
    return error.FileNotFound;
}

fn expectObjectExists(sandbox: *harness.Sandbox, hash: []const u8) !void {
    if (hash.len != 64) return error.InvalidHash;
    const gpa = std.testing.allocator;
    const io = sandbox.io;
    const path = try std.fmt.allocPrint(gpa, "{s}/.agit/objects/{s}/{s}", .{ sandbox.cwd, hash[0..2], hash[2..] });
    defer gpa.free(path);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    file.close(io);
}

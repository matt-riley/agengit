const std = @import("std");
const harness = @import("../support/harness.zig");

test "fsck/object_hash_mismatch" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try seedClaudeSession(&sandbox);
    try corruptFirstObject(&sandbox);

    var result = try sandbox.run(&.{ "fsck", "--json" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"command\":\"fsck\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"code\":\"object_hash_mismatch\"") != null);
}

fn corruptFirstObject(sandbox: *harness.Sandbox) !void {
    const io = std.testing.io;
    const objects_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.agit/objects", .{sandbox.cwd});
    defer std.testing.allocator.free(objects_path);

    var dir = try std.Io.Dir.cwd().openDir(io, objects_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const file_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ objects_path, entry.path });
        defer std.testing.allocator.free(file_path);
        var file = try std.Io.Dir.cwd().createFile(io, file_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "corrupt-object");
        return;
    }

    return error.FileNotFound;
}

fn seedClaudeSession(sandbox: *harness.Sandbox) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"Write a function to calculate factorial"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"abc123def456","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}}
    , .{sandbox.cwd});
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{ "claude-hook", "user" }, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{ "claude-hook", "assistant" }, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);
}

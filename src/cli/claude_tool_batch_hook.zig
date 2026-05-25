const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");

/// Entry point. Always exits cleanly — errors are logged to stderr.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = iter;
    runInner(io, gpa) catch |err| {
        hook.logError(io, "claude-tool-batch-hook", @errorName(err));
    };
}

fn runInner(io: std.Io, gpa: std.mem.Allocator) !void {
    const data = try hook.readStdin(io, gpa);
    defer gpa.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;

    const session_id = switch (root.get("session_id") orelse return error.MissingSessionId) {
        .string => |s| s,
        else => return error.InvalidSessionId,
    };

    const tool_calls_val = root.get("tool_calls") orelse return;
    const tool_calls = switch (tool_calls_val) {
        .array => |a| a,
        else => return error.InvalidToolCalls,
    };

    if (tool_calls.items.len == 0) return;

    var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "claude", .session_id = session_id };
    try rec.upsertSession(meta);

    for (tool_calls.items) |tc| {

        const tc_obj = switch (tc) {
            .object => |o| o,
            else => continue,
        };

        const tool_name = switch (tc_obj.get("tool_name") orelse continue) {
            .string => |s| s,
            else => continue,
        };

        const tool_input_val = tc_obj.get("tool_input") orelse std.json.Value.null;
        const tool_input_str = try std.json.Stringify.valueAlloc(gpa, tool_input_val, .{});
        defer gpa.free(tool_input_str);

        // Use raw string for tool_response when possible to avoid double-encoding.
        const tool_response_val = tc_obj.get("tool_response") orelse std.json.Value.null;
        var tool_response_allocated = false;
        const tool_response_str: []const u8 = switch (tool_response_val) {
            .string => |s| s,
            else => blk: {
                tool_response_allocated = true;
                break :blk try std.json.Stringify.valueAlloc(gpa, tool_response_val, .{});
            },
        };
        defer if (tool_response_allocated) gpa.free(tool_response_str);

        try rec.recordToolUse(io, meta, "", .{
            .tool_name = tool_name,
            .args = tool_input_str,
            .result = tool_response_str,
        });
    }
}

test "parse claude post tool batch fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/claude_post_tool_batch.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const session_id = root.get("session_id").?.string;
    try std.testing.expectEqualStrings("abc123def456", session_id);
    try std.testing.expectEqualStrings("PostToolBatch", root.get("hook_event_name").?.string);

    const tool_calls = root.get("tool_calls").?.array;
    try std.testing.expectEqual(@as(usize, 2), tool_calls.items.len);
    try std.testing.expectEqualStrings("Read", tool_calls.items[0].object.get("tool_name").?.string);
    try std.testing.expectEqualStrings("Bash", tool_calls.items[1].object.get("tool_name").?.string);
}

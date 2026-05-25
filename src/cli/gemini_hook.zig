const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");

/// Entry point. Always exits cleanly — errors are logged to stderr.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = iter;
    runInner(io, gpa) catch |err| {
        hook.logError(io, "gemini-hook", @errorName(err));
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

    const event = switch (root.get("hook_event_name") orelse return error.MissingEventName) {
        .string => |s| s,
        else => return error.InvalidEventName,
    };

    const meta: SessionMeta = .{ .origin = "gemini", .session_id = session_id };

    if (std.mem.eql(u8, event, "AfterTool")) {
        const tool_name = switch (root.get("tool_name") orelse std.json.Value{ .string = "unknown" }) {
            .string => |s| s,
            else => "unknown",
        };

        const tool_input_val = root.get("tool_input") orelse std.json.Value.null;
        const tool_input_str = try std.json.Stringify.valueAlloc(gpa, tool_input_val, .{});
        defer gpa.free(tool_input_str);

        const tool_response_val = root.get("tool_response") orelse std.json.Value.null;
        var tool_response_allocated = false;
        const tool_response_str: []const u8 = switch (tool_response_val) {
            .string => |s| s,
            else => blk: {
                tool_response_allocated = true;
                break :blk try std.json.Stringify.valueAlloc(gpa, tool_response_val, .{});
            },
        };
        defer if (tool_response_allocated) gpa.free(tool_response_str);

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        try rec.upsertSession(meta);
        try rec.recordToolUse(io, meta, "", .{
            .tool_name = tool_name,
            .args = tool_input_str,
            .result = tool_response_str,
        });
    } else if (std.mem.eql(u8, event, "AfterAgent")) {
        // Gemini uses "response" for the agent's final output.
        const content = switch (root.get("response") orelse std.json.Value{ .string = "" }) {
            .string => |s| s,
            else => "",
        };

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        try rec.recordAssistantAndFinalize(io, meta, "", .{ .content = content }, &.{});
    }
    // Unknown events are silently ignored.
}

test "parse gemini after tool fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/gemini_after_tool.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gemini-sess-001", root.get("session_id").?.string);
    try std.testing.expectEqualStrings("AfterTool", root.get("hook_event_name").?.string);
    try std.testing.expectEqualStrings("read_file", root.get("tool_name").?.string);
}

test "parse gemini after agent fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/gemini_after_agent.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gemini-sess-001", root.get("session_id").?.string);
    try std.testing.expectEqualStrings("AfterAgent", root.get("hook_event_name").?.string);
    try std.testing.expect(root.get("response").?.string.len > 0);
}

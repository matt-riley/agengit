const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");

/// Entry point. Always exits cleanly — errors are logged to stderr.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = iter;
    runInner(io, gpa) catch |err| {
        hook.logError(io, "codex-hook", @errorName(err));
    };
}

fn runInner(io: std.Io, gpa: std.mem.Allocator) !void {
    const data = try hook.readStdin(io, gpa);
    defer gpa.free(data);

    // Parse common fields first to dispatch on event name.
    const common = try std.json.parseFromSlice(hook.CommonPayload, gpa, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer common.deinit();

    const event = common.value.hook_event_name;
    const session_id = common.value.session_id;

    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        const parsed = try std.json.parseFromSlice(hook.ClaudeUserPayload, gpa, data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{ .origin = "codex", .session_id = session_id };
        try rec.upsertSession(meta);
        try rec.recordUserPrompt(io, meta, "", .{ .content = parsed.value.prompt });
    } else if (std.mem.eql(u8, event, "PostToolUse")) {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const root = parsed.value.object;

        const tool_name = switch (root.get("tool_name") orelse return error.MissingToolName) {
            .string => |s| s,
            else => return error.InvalidToolName,
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

        const meta: SessionMeta = .{ .origin = "codex", .session_id = session_id };
        try rec.recordToolUse(io, meta, "", .{
            .tool_name = tool_name,
            .args = tool_input_str,
            .result = tool_response_str,
        });
    } else if (std.mem.eql(u8, event, "Stop")) {
        const parsed = try std.json.parseFromSlice(hook.ClaudeStopPayload, gpa, data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{ .origin = "codex", .session_id = session_id };
        try rec.recordAssistantAndFinalize(io, meta, "", .{
            .content = parsed.value.last_assistant_message,
        }, &.{});
    }
    // Unknown events are silently ignored (forward-compatible).
}

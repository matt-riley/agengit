const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");

/// Entry point. Always exits cleanly — errors are logged to stderr.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = iter;
    runInner(io, gpa) catch {};
}

fn runInner(io: std.Io, gpa: std.mem.Allocator) !void {
    var diagnostic: hook.Diagnostic = .{};

    const payload_result = hook.readPayload(io, gpa) catch |err| {
        if (err == error.HookPayloadTooLarge) diagnostic = hook.Diagnostic.oversized();
        hook.reportFailure(io, gpa, .{
            .agent = "gemini-hook",
            .err = err,
            .diagnostic = diagnostic,
            .max_payload_bytes = hook.maxHookPayloadBytes(),
        });
        return err;
    };
    var payload = switch (payload_result) {
        .ok => |ok| ok,
        .err => |parse_err| {
            var parse = parse_err;
            defer parse.deinit(gpa);
            diagnostic = hook.Diagnostic.invalidJson();
            hook.reportFailure(io, gpa, .{
                .agent = "gemini-hook",
                .err = error.InvalidPayload,
                .diagnostic = diagnostic,
                .payload_size = parse.raw_size,
                .payload_snippet = parse.snippet,
                .parse_path = parse.path,
                .parse_offset = parse.offset,
                .parse_line = parse.line,
                .parse_column = parse.column,
                .max_payload_bytes = hook.maxHookPayloadBytes(),
            });
            return error.InvalidPayload;
        },
    };
    defer payload.deinit(gpa);

    processPayload(io, gpa, &payload, &diagnostic) catch |err| {
        if (err == error.LockTimeout) diagnostic = hook.Diagnostic.lockTimeout();
        hook.reportFailure(io, gpa, .{
            .agent = "gemini-hook",
            .err = err,
            .diagnostic = diagnostic,
            .session_id = payload.session_id,
            .event_name = payload.event_name,
            .payload = payload.raw,
            .max_payload_bytes = hook.maxHookPayloadBytes(),
        });
        return err;
    };
}

fn processPayload(
    io: std.Io,
    gpa: std.mem.Allocator,
    payload: *const hook.Payload,
    diagnostic: *hook.Diagnostic,
) !void {
    const root = try hook.requireObject(payload.parsed.value, diagnostic);

    const session_id = try hook.requireString(root, "session_id", diagnostic);
    _ = try hook.requireString(root, "cwd", diagnostic);
    const event = try hook.requireString(root, "hook_event_name", diagnostic);

    const meta: SessionMeta = .{ .origin = "gemini", .session_id = session_id };

    if (std.mem.eql(u8, event, "AfterTool")) {
        const maybe_tool_name = root.get("tool_name");
        const malformed_reason: ?[]const u8 = if (maybe_tool_name) |value| switch (value) {
            .string => null,
            else => "invalid tool_name",
        } else "missing tool_name";
        const tool_name = if (maybe_tool_name) |value| switch (value) {
            .string => |s| s,
            else => "unknown",
        } else "unknown";

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        try rec.upsertSession(meta);

        if (malformed_reason) |reason| {
            const args = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = root }, .{});
            defer gpa.free(args);
            try rec.recordToolUse(io, meta, "", .{
                .tool_name = tool_name,
                .args = args,
                .result = reason,
            });
            return;
        }

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

        try rec.recordToolUse(io, meta, "", .{
            .tool_name = tool_name,
            .args = tool_input_str,
            .result = tool_response_str,
        });
    } else if (std.mem.eql(u8, event, "AfterAgent")) {
        // Gemini uses "response" for the agent's final output.
        const content = (try hook.optionalString(root, "response", diagnostic)) orelse "";

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        try rec.recordAssistantAndFinalize(io, meta, "", .{ .content = content }, &.{});
    } else {
        diagnostic.* = hook.Diagnostic.unknownEvent();
        return error.UnknownEventName;
    }
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

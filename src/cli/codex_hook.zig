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

    const data = hook.readStdin(io, gpa) catch |err| {
        if (err == error.HookPayloadTooLarge) diagnostic = hook.Diagnostic.oversized();
        hook.reportFailure(io, gpa, "codex-hook", err, diagnostic, null);
        return err;
    };
    defer gpa.free(data);

    processPayload(io, gpa, data, &diagnostic) catch |err| {
        if (err == error.LockTimeout) diagnostic = hook.Diagnostic.lockTimeout();
        hook.reportFailure(io, gpa, "codex-hook", err, diagnostic, data);
        return err;
    };
}

fn processPayload(
    io: std.Io,
    gpa: std.mem.Allocator,
    data: []const u8,
    diagnostic: *hook.Diagnostic,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = try hook.requireObject(parsed.value, diagnostic);
    const event = try hook.requireString(root, "hook_event_name", diagnostic);
    const session_id = try hook.requireString(root, "session_id", diagnostic);
    _ = try hook.requireString(root, "cwd", diagnostic);

    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        const prompt = try hook.requireString(root, "prompt", diagnostic);

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{ .origin = "codex", .session_id = session_id };
        try rec.upsertSession(meta);
        try rec.recordUserPrompt(io, meta, "", .{ .content = prompt });
    } else if (std.mem.eql(u8, event, "PostToolUse")) {
        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{ .origin = "codex", .session_id = session_id };
        try rec.upsertSession(meta);
        try recordToolEvent(io, gpa, &rec, meta, root);
    } else if (std.mem.eql(u8, event, "Stop")) {
        const content = (try hook.optionalString(root, "last_assistant_message", diagnostic)) orelse "";

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{ .origin = "codex", .session_id = session_id };
        try rec.recordAssistantAndFinalize(io, meta, "", .{
            .content = content,
        }, &.{});
    } else {
        diagnostic.* = hook.Diagnostic.unknownEvent();
        return error.UnknownEventName;
    }
}

fn recordToolEvent(
    io: std.Io,
    gpa: std.mem.Allocator,
    rec: *Recorder,
    meta: SessionMeta,
    root: std.json.ObjectMap,
) !void {
    const maybe_tool_name = root.get("tool_name");
    const malformed_reason: ?[]const u8 = if (maybe_tool_name) |value| switch (value) {
        .string => null,
        else => "invalid tool_name",
    } else "missing tool_name";
    const tool_name = if (maybe_tool_name) |value| switch (value) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";

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
}

test "codex malformed tool event records unknown placeholder" {
    const gpa = std.testing.allocator;
    const data =
        \\{
        \\  "session_id": "codex-sess-001",
        \\  "cwd": "/repo",
        \\  "hook_event_name": "PostToolUse",
        \\  "tool_input": {"command": "true"}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const root = parsed.value.object;

    const maybe_tool_name = root.get("tool_name");
    const tool_name = if (maybe_tool_name) |value| switch (value) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";
    try std.testing.expectEqualStrings("unknown", tool_name);
}

test "parse codex user prompt fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/codex_user_prompt.json");
    const common = try std.json.parseFromSlice(hook.CommonPayload, gpa, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer common.deinit();
    try std.testing.expectEqualStrings("codex-sess-001", common.value.session_id);
    try std.testing.expectEqualStrings("UserPromptSubmit", common.value.hook_event_name);

    const parsed = try std.json.parseFromSlice(hook.ClaudeUserPayload, gpa, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.prompt.len > 0);
}

test "parse codex post tool use fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/codex_post_tool_use.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("codex-sess-001", root.get("session_id").?.string);
    try std.testing.expectEqualStrings("PostToolUse", root.get("hook_event_name").?.string);
    try std.testing.expectEqualStrings("bash", root.get("tool_name").?.string);
}

test "parse codex stop fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/codex_stop.json");
    const parsed = try std.json.parseFromSlice(hook.ClaudeStopPayload, gpa, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("codex-sess-001", parsed.value.session_id);
    try std.testing.expectEqualStrings("Stop", parsed.value.hook_event_name);
    try std.testing.expect(parsed.value.last_assistant_message.len > 0);
}

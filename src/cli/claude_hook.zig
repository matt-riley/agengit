const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");

/// Entry point. Always exits cleanly — errors are logged to stderr.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    runInner(io, gpa, iter) catch {};
}

fn runInner(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var diagnostic: hook.Diagnostic = .{};

    const subcommand = iter.next() orelse {
        diagnostic = .{ .code = "missing_subcommand", .message = "claude hook subcommand is required" };
        hook.reportFailure(io, gpa, .{
            .agent = "claude-hook",
            .err = error.MissingSubcommand,
            .diagnostic = diagnostic,
        });
        return error.MissingSubcommand;
    };

    const payload_result = hook.readPayload(io, gpa) catch |err| {
        if (err == error.HookPayloadTooLarge) diagnostic = hook.Diagnostic.oversized();
        hook.reportFailure(io, gpa, .{
            .agent = "claude-hook",
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
                .agent = "claude-hook",
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

    processPayload(io, gpa, subcommand, &payload, &diagnostic) catch |err| {
        if (err == error.LockTimeout) diagnostic = hook.Diagnostic.lockTimeout();
        hook.reportFailure(io, gpa, .{
            .agent = "claude-hook",
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
    subcommand: []const u8,
    payload: *const hook.Payload,
    diagnostic: *hook.Diagnostic,
) !void {
    const root = try hook.requireObject(payload.parsed.value, diagnostic);

    if (std.mem.eql(u8, subcommand, "user")) {
        const event = try hook.requireString(root, "hook_event_name", diagnostic);
        try hook.requireEvent(event, "UserPromptSubmit", diagnostic);
        const session_id = try hook.requireString(root, "session_id", diagnostic);
        _ = try hook.requireString(root, "cwd", diagnostic);
        const prompt = try hook.requireString(root, "prompt", diagnostic);

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{
            .origin = "claude",
            .session_id = session_id,
        };
        try rec.upsertSession(meta);
        try rec.recordUserPrompt(io, meta, "", .{ .content = prompt });
    } else if (std.mem.eql(u8, subcommand, "assistant")) {
        const event = try hook.requireString(root, "hook_event_name", diagnostic);
        try hook.requireEvent(event, "Stop", diagnostic);
        const session_id = try hook.requireString(root, "session_id", diagnostic);
        _ = try hook.requireString(root, "cwd", diagnostic);
        const content = (try hook.optionalString(root, "last_assistant_message", diagnostic)) orelse "";

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{
            .origin = "claude",
            .session_id = session_id,
        };
        try rec.recordAssistantAndFinalize(io, meta, "", .{
            .content = content,
        }, &.{});
    } else {
        diagnostic.* = .{ .code = "unknown_subcommand", .message = "claude hook subcommand is unknown" };
        return error.UnknownSubcommand;
    }
}

test "parse claude user prompt fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/claude_user_prompt.json");
    const parsed = try std.json.parseFromSlice(hook.ClaudeUserPayload, gpa, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc123def456", parsed.value.session_id);
    try std.testing.expectEqualStrings("Write a function to calculate factorial", parsed.value.prompt);
    try std.testing.expectEqualStrings("UserPromptSubmit", parsed.value.hook_event_name);
}

test "parse claude stop fixture" {
    const gpa = std.testing.allocator;
    const data = @embedFile("../fixtures/hooks/claude_stop.json");
    const parsed = try std.json.parseFromSlice(hook.ClaudeStopPayload, gpa, data, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc123def456", parsed.value.session_id);
    try std.testing.expectEqualStrings("Stop", parsed.value.hook_event_name);
    try std.testing.expect(parsed.value.last_assistant_message.len > 0);
}

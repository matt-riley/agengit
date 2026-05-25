const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");
const event_mod = @import("../hook/event.zig");

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
            .workspace_cwd = payload.cwd,
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
        const workspace_cwd = try hook.requireString(root, "cwd", diagnostic);
        const prompt = try hook.requireString(root, "prompt", diagnostic);
        const preferred_turn_id = try hook.optionalString(root, "turn_id", diagnostic);
        const source_event_id = try hook.optionalString(root, "event_id", diagnostic);

        var workspace = try event_mod.openWorkspaceDir(io, workspace_cwd);
        defer workspace.dir.close(io);

        var rec = try Recorder.open(io, workspace.dir, gpa);
        defer rec.deinit(io);

        var normalized = try event_mod.normalize(io, gpa, &rec, root, diagnostic, .{
            .origin = "claude",
            .expected_event_name = "UserPromptSubmit",
            .kind = .user_prompt,
            .source_event_id = source_event_id,
            .preferred_turn_id = preferred_turn_id,
        });
        defer normalized.deinit(io, gpa);

        if (workspace.used_fallback) {
            rec.logHookFailure(io, "claude-hook", error.InvalidCwd, .{
                .agent = "claude-hook",
                .code = "workspace_cwd_fallback",
                .message = "payload cwd could not be opened; used hook process cwd fallback",
                .session_id = normalized.session_id,
                .event_name = normalized.event_name,
            });
        }

        const meta: SessionMeta = .{ .origin = normalized.origin, .session_id = normalized.session_id };
        try rec.upsertSession(meta);
        try rec.recordUserPrompt(io, meta, normalized.turn_id, .{ .content = prompt });
    } else if (std.mem.eql(u8, subcommand, "assistant")) {
        const workspace_cwd = try hook.requireString(root, "cwd", diagnostic);
        const content = (try hook.optionalString(root, "last_assistant_message", diagnostic)) orelse "";
        const preferred_turn_id = try hook.optionalString(root, "turn_id", diagnostic);
        const source_event_id = try hook.optionalString(root, "event_id", diagnostic);

        var workspace = try event_mod.openWorkspaceDir(io, workspace_cwd);
        defer workspace.dir.close(io);

        var rec = try Recorder.open(io, workspace.dir, gpa);
        defer rec.deinit(io);

        var normalized = try event_mod.normalize(io, gpa, &rec, root, diagnostic, .{
            .origin = "claude",
            .expected_event_name = "Stop",
            .kind = .assistant,
            .source_event_id = source_event_id,
            .preferred_turn_id = preferred_turn_id,
        });
        defer normalized.deinit(io, gpa);

        if (workspace.used_fallback) {
            rec.logHookFailure(io, "claude-hook", error.InvalidCwd, .{
                .agent = "claude-hook",
                .code = "workspace_cwd_fallback",
                .message = "payload cwd could not be opened; used hook process cwd fallback",
                .session_id = normalized.session_id,
                .event_name = normalized.event_name,
            });
        }

        if (normalized.recovered_turn) {
            rec.logHookFailure(io, "claude-hook", error.MissingActiveTurn, .{
                .agent = "claude-hook",
                .code = "recovery_turn_id",
                .message = "assistant event arrived without an active turn; generated recovery turn id",
                .session_id = normalized.session_id,
                .event_name = normalized.event_name,
            });
        }

        const meta: SessionMeta = .{ .origin = normalized.origin, .session_id = normalized.session_id };
        try rec.recordAssistantAndFinalize(io, meta, normalized.turn_id, .{
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

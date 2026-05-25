const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");
const event_mod = @import("../hook/event.zig");

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
            .agent = "claude-tool-batch-hook",
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
                .agent = "claude-tool-batch-hook",
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
            .agent = "claude-tool-batch-hook",
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
    payload: *const hook.Payload,
    diagnostic: *hook.Diagnostic,
) !void {
    const root = try hook.requireObject(payload.parsed.value, diagnostic);

    const workspace_cwd = try hook.requireString(root, "cwd", diagnostic);
    const preferred_turn_id = try hook.optionalString(root, "turn_id", diagnostic);

    const tool_calls_val = root.get("tool_calls") orelse {
        diagnostic.* = hook.Diagnostic.missing("tool_calls");
        return error.MissingRequiredField;
    };
    const tool_calls = switch (tool_calls_val) {
        .array => |a| a,
        else => {
            diagnostic.* = hook.Diagnostic.invalid("tool_calls");
            return error.InvalidFieldType;
        },
    };

    if (tool_calls.items.len == 0) return;

    var workspace = try event_mod.openWorkspaceDir(io, workspace_cwd);
    defer workspace.dir.close(io);

    var rec = try Recorder.open(io, workspace.dir, gpa);
    defer rec.deinit(io);

    var normalized = try event_mod.normalize(io, gpa, &rec, root, diagnostic, .{
        .origin = "claude",
        .expected_event_name = "PostToolBatch",
        .kind = .tool_use,
        .preferred_turn_id = preferred_turn_id,
    });
    defer normalized.deinit(io, gpa);

    if (workspace.used_fallback) {
        rec.logHookFailure(io, "claude-tool-batch-hook", error.InvalidCwd, .{
            .agent = "claude-tool-batch-hook",
            .code = "workspace_cwd_fallback",
            .message = "payload cwd could not be opened; used hook process cwd fallback",
            .session_id = normalized.session_id,
            .event_name = normalized.event_name,
        });
    }

    if (normalized.recovered_turn) {
        rec.logHookFailure(io, "claude-tool-batch-hook", error.MissingActiveTurn, .{
            .agent = "claude-tool-batch-hook",
            .code = "recovery_turn_id",
            .message = "tool event arrived without an active turn; generated recovery turn id",
            .session_id = normalized.session_id,
            .event_name = normalized.event_name,
        });
    }

    const meta: SessionMeta = .{ .origin = normalized.origin, .session_id = normalized.session_id };
    try rec.upsertSession(meta);

    for (tool_calls.items) |tc| {
        const tc_obj = switch (tc) {
            .object => |o| o,
            else => {
                try recordMalformedTool(io, gpa, &rec, meta, normalized.turn_id, tc, "tool entry is not an object");
                continue;
            },
        };

        const tool_name = switch (tc_obj.get("tool_name") orelse {
            try recordMalformedTool(io, gpa, &rec, meta, normalized.turn_id, tc, "missing tool_name");
            continue;
        }) {
            .string => |s| s,
            else => {
                try recordMalformedTool(io, gpa, &rec, meta, normalized.turn_id, tc, "invalid tool_name");
                continue;
            },
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

        try rec.recordToolUse(io, meta, normalized.turn_id, .{
            .tool_name = tool_name,
            .args = tool_input_str,
            .result = tool_response_str,
        });
    }
}

fn recordMalformedTool(
    io: std.Io,
    gpa: std.mem.Allocator,
    rec: *Recorder,
    meta: SessionMeta,
    turn_id: []const u8,
    value: std.json.Value,
    reason: []const u8,
) !void {
    const args = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(args);
    try rec.recordToolUse(io, meta, turn_id, .{
        .tool_name = "unknown",
        .args = args,
        .result = reason,
    });
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

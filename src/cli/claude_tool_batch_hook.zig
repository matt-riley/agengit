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
        hook.reportFailure(io, gpa, "claude-tool-batch-hook", err, diagnostic, null);
        return err;
    };
    defer gpa.free(data);

    processPayload(io, gpa, data, &diagnostic) catch |err| {
        hook.reportFailure(io, gpa, "claude-tool-batch-hook", err, diagnostic, data);
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

    const session_id = try hook.requireString(root, "session_id", diagnostic);
    _ = try hook.requireString(root, "cwd", diagnostic);
    const event = try hook.requireString(root, "hook_event_name", diagnostic);
    try hook.requireEvent(event, "PostToolBatch", diagnostic);

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

    var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
    defer rec.deinit(io);

    const meta: SessionMeta = .{ .origin = "claude", .session_id = session_id };
    try rec.upsertSession(meta);

    for (tool_calls.items) |tc| {
        const tc_obj = switch (tc) {
            .object => |o| o,
            else => {
                try recordMalformedTool(io, gpa, &rec, meta, tc, "tool entry is not an object");
                continue;
            },
        };

        const tool_name = switch (tc_obj.get("tool_name") orelse {
            try recordMalformedTool(io, gpa, &rec, meta, tc, "missing tool_name");
            continue;
        }) {
            .string => |s| s,
            else => {
                try recordMalformedTool(io, gpa, &rec, meta, tc, "invalid tool_name");
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

        try rec.recordToolUse(io, meta, "", .{
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
    value: std.json.Value,
    reason: []const u8,
) !void {
    const args = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(args);
    try rec.recordToolUse(io, meta, "", .{
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

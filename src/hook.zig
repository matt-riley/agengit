const std = @import("std");
const recorder_mod = @import("recorder.zig");

/// Maximum accepted hook payload size.
///
/// Agent hooks run on every turn/tool event, so stdin is intentionally capped at
/// 1 MiB to keep malformed or hostile hook input from exhausting memory. Hook
/// entrypoints catch this error and log it without blocking the agent command.
pub const max_hook_payload_bytes: usize = 1024 * 1024;

pub const HookInputError = error{
    HookPayloadTooLarge,
};

pub const ValidationError = error{
    MissingRequiredField,
    InvalidFieldType,
    UnknownEventName,
};

pub const Diagnostic = struct {
    code: []const u8 = "hook_error",
    message: []const u8 = "hook failed",
    field: ?[]const u8 = null,

    pub fn missing(field: []const u8) Diagnostic {
        return .{
            .code = "missing_required_field",
            .message = "hook payload is missing a required field",
            .field = field,
        };
    }

    pub fn invalid(field: []const u8) Diagnostic {
        return .{
            .code = "invalid_field_type",
            .message = "hook payload field has an invalid type",
            .field = field,
        };
    }

    pub fn unknownEvent() Diagnostic {
        return .{
            .code = "unknown_event_name",
            .message = "hook payload has an unknown event name",
            .field = "hook_event_name",
        };
    }

    pub fn oversized() Diagnostic {
        return .{
            .code = "oversized_payload",
            .message = "hook payload exceeds the maximum accepted size",
        };
    }

    pub fn lockTimeout() Diagnostic {
        return .{
            .code = "lock_timeout",
            .message = "timed out waiting for a lock; set AGIT_LOCK_TIMEOUT_MS to a higher value if needed",
        };
    }
};

/// Read all bytes from a hook payload reader into a heap-allocated buffer.
/// Caller owns the returned slice.
pub fn readHookPayload(reader: *std.Io.Reader, gpa: std.mem.Allocator) ![]u8 {
    return reader.allocRemaining(gpa, .limited(max_hook_payload_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.HookPayloadTooLarge,
        else => |e| e,
    };
}

/// Read all bytes from stdin into a heap-allocated buffer.
/// Caller owns the returned slice.
pub fn readStdin(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var read_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &read_buf);
    return readHookPayload(&stdin_reader.interface, gpa);
}

/// Write a best-effort error line to stderr. Never propagates errors.
pub fn logError(io: std.Io, context: []const u8, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("[agit hook error] {s}: {s}\n", .{ context, msg }) catch {};
    w.flush() catch {};
}

/// Best-effort structured hook failure logging.
///
/// Writes a durable JSONL entry into `.agit/log/hook-error.log` when the current
/// directory belongs to an agit store, and always mirrors a short non-blocking
/// error to stderr.
pub fn reportFailure(
    io: std.Io,
    gpa: std.mem.Allocator,
    context: []const u8,
    err: anyerror,
    diagnostic: Diagnostic,
    payload: ?[]const u8,
) void {
    logError(io, context, @errorName(err));

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();

    var session_id: ?[]const u8 = null;
    var event_name: ?[]const u8 = null;
    if (payload) |data| {
        parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{
            .allocate = .alloc_always,
        }) catch null;
        if (parsed) |p| {
            if (p.value == .object) {
                const root = p.value.object;
                if (root.get("session_id")) |value| {
                    if (value == .string) session_id = value.string;
                }
                if (root.get("hook_event_name")) |value| {
                    if (value == .string) event_name = value.string;
                }
            }
        }
    }

    recorder_mod.logHookFailureFromCwd(io, gpa, context, err, .{
        .code = diagnostic.code,
        .message = diagnostic.message,
        .field = diagnostic.field,
        .session_id = session_id,
        .event_name = event_name,
        .payload_bytes = if (payload) |data| data.len else null,
        .max_payload_bytes = max_hook_payload_bytes,
    });
}

pub fn requireObject(value: std.json.Value, diagnostic: *Diagnostic) ValidationError!std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => {
            diagnostic.* = Diagnostic.invalid("$");
            return error.InvalidFieldType;
        },
    };
}

pub fn requireString(
    root: std.json.ObjectMap,
    field: []const u8,
    diagnostic: *Diagnostic,
) ValidationError![]const u8 {
    const value = root.get(field) orelse {
        diagnostic.* = Diagnostic.missing(field);
        return error.MissingRequiredField;
    };
    return switch (value) {
        .string => |s| s,
        else => {
            diagnostic.* = Diagnostic.invalid(field);
            return error.InvalidFieldType;
        },
    };
}

pub fn optionalString(
    root: std.json.ObjectMap,
    field: []const u8,
    diagnostic: *Diagnostic,
) ValidationError!?[]const u8 {
    const value = root.get(field) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => {
            diagnostic.* = Diagnostic.invalid(field);
            return error.InvalidFieldType;
        },
    };
}

pub fn requireEvent(
    actual: []const u8,
    expected: []const u8,
    diagnostic: *Diagnostic,
) ValidationError!void {
    if (!std.mem.eql(u8, actual, expected)) {
        diagnostic.* = Diagnostic.unknownEvent();
        return error.UnknownEventName;
    }
}

/// UserPromptSubmit payload (Claude Code).
pub const ClaudeUserPayload = struct {
    session_id: []const u8,
    transcript_path: []const u8 = "",
    cwd: []const u8,
    hook_event_name: []const u8,
    prompt: []const u8,
};

/// Stop payload (Claude Code).
pub const ClaudeStopPayload = struct {
    session_id: []const u8,
    transcript_path: []const u8 = "",
    cwd: []const u8,
    hook_event_name: []const u8,
    stop_hook_active: bool = false,
    last_assistant_message: []const u8 = "",
};

/// Common fields present in all agent hook payloads.
pub const CommonPayload = struct {
    session_id: []const u8,
    cwd: []const u8,
    hook_event_name: []const u8,
};

test "readHookPayload rejects oversized input" {
    const gpa = std.testing.allocator;
    const oversized = try gpa.alloc(u8, max_hook_payload_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');

    var reader: std.Io.Reader = .fixed(oversized);
    try std.testing.expectError(error.HookPayloadTooLarge, readHookPayload(&reader, gpa));
}

test "requireString reports missing and invalid fields" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"ok\":\"yes\",\"bad\":1}", .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var diagnostic: Diagnostic = .{};
    const root = try requireObject(parsed.value, &diagnostic);

    try std.testing.expectEqualStrings("yes", try requireString(root, "ok", &diagnostic));
    try std.testing.expectError(error.MissingRequiredField, requireString(root, "missing", &diagnostic));
    try std.testing.expectEqualStrings("missing_required_field", diagnostic.code);
    try std.testing.expectEqualStrings("missing", diagnostic.field.?);

    try std.testing.expectError(error.InvalidFieldType, requireString(root, "bad", &diagnostic));
    try std.testing.expectEqualStrings("invalid_field_type", diagnostic.code);
    try std.testing.expectEqualStrings("bad", diagnostic.field.?);
}

test "requireEvent reports unknown event names" {
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.UnknownEventName, requireEvent("Mystery", "Known", &diagnostic));
    try std.testing.expectEqualStrings("unknown_event_name", diagnostic.code);
}

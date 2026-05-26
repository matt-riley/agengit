const std = @import("std");
const redact_mod = @import("privacy/redact.zig");
const recorder_mod = @import("recorder.zig");

/// Default maximum accepted hook payload size.
pub const default_max_hook_payload_bytes: usize = 16 * 1024 * 1024;

var configured_max_hook_payload_bytes = std.atomic.Value(usize).init(default_max_hook_payload_bytes);

pub const HookInputError = error{
    HookPayloadTooLarge,
};

pub const ValidationError = error{
    MissingRequiredField,
    InvalidFieldType,
    UnknownEventName,
};

pub fn configureFromEnviron(environ: std.process.Environ) void {
    const raw = environ.getPosix("AGIT_HOOK_MAX_BYTES") orelse {
        configured_max_hook_payload_bytes.store(default_max_hook_payload_bytes, .release);
        return;
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        configured_max_hook_payload_bytes.store(default_max_hook_payload_bytes, .release);
        return;
    }
    const parsed = std.fmt.parseInt(usize, trimmed, 10) catch {
        configured_max_hook_payload_bytes.store(default_max_hook_payload_bytes, .release);
        return;
    };
    configured_max_hook_payload_bytes.store(if (parsed > 0) parsed else default_max_hook_payload_bytes, .release);
}

pub fn maxHookPayloadBytes() usize {
    return configured_max_hook_payload_bytes.load(.acquire);
}

pub const PayloadParseError = struct {
    path: []const u8 = "stdin",
    offset: usize,
    line: usize,
    column: usize,
    snippet: []u8,
    raw_size: usize,

    pub fn deinit(self: *PayloadParseError, gpa: std.mem.Allocator) void {
        gpa.free(self.snippet);
        self.* = undefined;
    }
};

pub const Payload = struct {
    raw: []u8,
    parsed: std.json.Parsed(std.json.Value),
    session_id: ?[]const u8 = null,
    event_name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,

    pub fn deinit(self: *Payload, gpa: std.mem.Allocator) void {
        self.parsed.deinit();
        gpa.free(self.raw);
        self.* = undefined;
    }
};

pub const ReadPayloadResult = union(enum) {
    ok: Payload,
    err: PayloadParseError,
};

pub const FailureContext = struct {
    agent: []const u8,
    err: anyerror,
    diagnostic: Diagnostic = .{},
    session_id: ?[]const u8 = null,
    event_name: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    payload_size: ?usize = null,
    payload_snippet: ?[]const u8 = null,
    parse_path: ?[]const u8 = null,
    parse_offset: ?usize = null,
    parse_line: ?usize = null,
    parse_column: ?usize = null,
    max_payload_bytes: ?usize = null,
    workspace_cwd: ?[]const u8 = null,
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

    pub fn invalidJson() Diagnostic {
        return .{
            .code = "invalid_json_payload",
            .message = "hook payload is not valid JSON",
            .field = "$",
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
pub fn readHookPayload(reader: *std.Io.Reader, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
    return reader.allocRemaining(gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => error.HookPayloadTooLarge,
        else => |e| e,
    };
}

pub fn readPayload(io: std.Io, gpa: std.mem.Allocator) !ReadPayloadResult {
    const max_bytes = maxHookPayloadBytes();
    var read_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &read_buf);
    const data = try readHookPayload(&stdin_reader.interface, gpa, max_bytes);
    return parsePayloadData(gpa, data);
}

pub fn parsePayloadBytes(gpa: std.mem.Allocator, data: []const u8) !ReadPayloadResult {
    return parsePayloadData(gpa, try gpa.dupe(u8, data));
}

/// Write a best-effort error line to stderr. Never propagates errors.
fn logError(io: std.Io, context: []const u8, msg: []const u8) void {
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
pub fn reportFailure(io: std.Io, gpa: std.mem.Allocator, ctx: FailureContext) void {
    var stderr_msg_buf: [320]u8 = undefined;
    const stderr_msg = if (ctx.parse_offset) |offset|
        std.fmt.bufPrint(
            &stderr_msg_buf,
            "{s} at byte offset {d} (line {d}, column {d})",
            .{
                ctx.diagnostic.message,
                offset,
                ctx.parse_line orelse 0,
                ctx.parse_column orelse 0,
            },
        ) catch ctx.diagnostic.message
    else
        ctx.diagnostic.message;
    logError(io, ctx.agent, stderr_msg);

    var generated_snippet: ?[]u8 = null;
    defer if (generated_snippet) |snippet| gpa.free(snippet);
    const snippet = if (ctx.payload_snippet) |provided| blk: {
        break :blk provided;
    } else if (ctx.payload) |raw| blk: {
        generated_snippet = redactSnippetAlloc(gpa, raw) catch null;
        break :blk generated_snippet;
    } else null;

    if (ctx.workspace_cwd) |workspace_cwd| {
        const dir = std.Io.Dir.cwd().openDir(io, workspace_cwd, .{}) catch {
            recorder_mod.logHookFailureFromCwd(io, gpa, ctx.agent, ctx.err, .{
                .agent = ctx.agent,
                .code = ctx.diagnostic.code,
                .message = ctx.diagnostic.message,
                .field = ctx.diagnostic.field,
                .session_id = ctx.session_id,
                .event_name = ctx.event_name,
                .payload_bytes = ctx.payload_size orelse if (ctx.payload) |raw| raw.len else null,
                .payload_snippet = snippet,
                .parse_path = ctx.parse_path,
                .parse_offset = ctx.parse_offset,
                .parse_line = ctx.parse_line,
                .parse_column = ctx.parse_column,
                .max_payload_bytes = ctx.max_payload_bytes orelse maxHookPayloadBytes(),
            });
            return;
        };
        defer dir.close(io);
        recorder_mod.logHookFailureFromDir(io, gpa, dir, ctx.agent, ctx.err, .{
            .agent = ctx.agent,
            .code = ctx.diagnostic.code,
            .message = ctx.diagnostic.message,
            .field = ctx.diagnostic.field,
            .session_id = ctx.session_id,
            .event_name = ctx.event_name,
            .payload_bytes = ctx.payload_size orelse if (ctx.payload) |raw| raw.len else null,
            .payload_snippet = snippet,
            .parse_path = ctx.parse_path,
            .parse_offset = ctx.parse_offset,
            .parse_line = ctx.parse_line,
            .parse_column = ctx.parse_column,
            .max_payload_bytes = ctx.max_payload_bytes orelse maxHookPayloadBytes(),
        });
        return;
    }

    recorder_mod.logHookFailureFromCwd(io, gpa, ctx.agent, ctx.err, .{
        .agent = ctx.agent,
        .code = ctx.diagnostic.code,
        .message = ctx.diagnostic.message,
        .field = ctx.diagnostic.field,
        .session_id = ctx.session_id,
        .event_name = ctx.event_name,
        .payload_bytes = ctx.payload_size orelse if (ctx.payload) |raw| raw.len else null,
        .payload_snippet = snippet,
        .parse_path = ctx.parse_path,
        .parse_offset = ctx.parse_offset,
        .parse_line = ctx.parse_line,
        .parse_column = ctx.parse_column,
        .max_payload_bytes = ctx.max_payload_bytes orelse maxHookPayloadBytes(),
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

fn parsePayloadData(gpa: std.mem.Allocator, data: []u8) !ReadPayloadResult {
    var scanner = std.json.Scanner.initCompleteInput(gpa, data);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    const parsed = std.json.parseFromTokenSource(std.json.Value, gpa, &scanner, .{
        .allocate = .alloc_always,
    }) catch {
        const snippet = try redactSnippetAlloc(gpa, data);
        const raw_size = data.len;
        gpa.free(data);
        return .{ .err = .{
            .offset = @intCast(diagnostics.getByteOffset()),
            .line = @intCast(diagnostics.getLine()),
            .column = @intCast(diagnostics.getColumn()),
            .snippet = snippet,
            .raw_size = raw_size,
        } };
    };

    var payload: Payload = .{
        .raw = data,
        .parsed = parsed,
    };
    if (parsed.value == .object) {
        const root = parsed.value.object;
        if (root.get("session_id")) |value| {
            if (value == .string) payload.session_id = value.string;
        }
        if (root.get("hook_event_name")) |value| {
            if (value == .string) payload.event_name = value.string;
        }
        if (root.get("cwd")) |value| {
            if (value == .string) payload.cwd = value.string;
        }
    }
    return .{ .ok = payload };
}

fn redactSnippetAlloc(gpa: std.mem.Allocator, payload: []const u8) ![]u8 {
    const end = @min(payload.len, 256);
    return redact_mod.redactAlloc(gpa, payload[0..end], .{});
}

test "readHookPayload rejects oversized input" {
    const gpa = std.testing.allocator;
    const oversized = try gpa.alloc(u8, 64);
    defer gpa.free(oversized);
    @memset(oversized, 'x');

    var reader: std.Io.Reader = .fixed(oversized);
    try std.testing.expectError(error.HookPayloadTooLarge, readHookPayload(&reader, gpa, 32));
}

test "parsePayloadData returns structured parse diagnostics" {
    const gpa = std.testing.allocator;
    const data = try gpa.dupe(u8, "{\"session_id\":\"abc\",");
    const result = try parsePayloadData(gpa, data);
    try std.testing.expect(result == .err);
    var parse_err = result.err;
    defer parse_err.deinit(gpa);
    try std.testing.expect(parse_err.offset > 0);
    try std.testing.expectEqual(@as(usize, 20), parse_err.raw_size);
    try std.testing.expect(parse_err.snippet.len > 0);
}

test "redactSnippetAlloc masks sensitive values" {
    const gpa = std.testing.allocator;
    const payload =
        \\{"token":"abc123","password":"hunter2","authorization":"Bearer xyz","normal":"visible"}
    ;
    const snippet = try redactSnippetAlloc(gpa, payload);
    defer gpa.free(snippet);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "Bearer xyz") == null);
    try std.testing.expect(std.mem.indexOf(u8, snippet, "visible") != null);
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

const std = @import("std");

/// Read all bytes from stdin into a heap-allocated buffer.
/// Caller owns the returned slice.
pub fn readStdin(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var read_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &read_buf);
    return stdin_reader.interface.allocRemaining(gpa, .unlimited);
}

/// Write a best-effort error line to stderr. Never propagates errors.
pub fn logError(io: std.Io, context: []const u8, msg: []const u8) void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print("[agit hook error] {s}: {s}\n", .{ context, msg }) catch {};
    w.flush() catch {};
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

test "readStdin compiles" {
    // Structural compile-check only; no stdin available in test runner.
    _ = readStdin;
}

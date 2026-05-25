const std = @import("std");
const recorder_mod = @import("../recorder.zig");
const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;
const hook = @import("../hook.zig");

/// Entry point. Always exits cleanly — errors are logged to stderr.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    runInner(io, gpa, iter) catch |err| {
        hook.logError(io, "claude-hook", @errorName(err));
    };
}

fn runInner(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    const subcommand = iter.next() orelse return error.MissingSubcommand;

    const data = try hook.readStdin(io, gpa);
    defer gpa.free(data);

    if (std.mem.eql(u8, subcommand, "user")) {
        const parsed = try std.json.parseFromSlice(hook.ClaudeUserPayload, gpa, data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{
            .origin = "claude",
            .session_id = parsed.value.session_id,
        };
        try rec.upsertSession(meta);
        try rec.recordUserPrompt(io, meta, "", .{ .content = parsed.value.prompt });
    } else if (std.mem.eql(u8, subcommand, "assistant")) {
        const parsed = try std.json.parseFromSlice(hook.ClaudeStopPayload, gpa, data, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var rec = try Recorder.open(io, std.Io.Dir.cwd(), gpa);
        defer rec.deinit(io);

        const meta: SessionMeta = .{
            .origin = "claude",
            .session_id = parsed.value.session_id,
        };
        try rec.recordAssistantAndFinalize(io, meta, "", .{
            .content = parsed.value.last_assistant_message,
        }, &.{});
    } else {
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

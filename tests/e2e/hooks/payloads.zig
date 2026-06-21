const std = @import("std");
const harness = @import("../support/harness.zig");

const Case = struct {
    origin: []const u8,
    steps: []const Step,
};

const Step = struct {
    args: []const []const u8,
    payload_path: []const u8,
};

test "hooks/payloads" {
    const cases = [_]Case{
        .{
            .origin = "claude",
            .steps = &.{
                .{ .args = &.{ "claude-hook", "user" }, .payload_path = "src/fixtures/hooks/claude_user_prompt.json" },
                .{ .args = &.{"claude-tool-batch-hook"}, .payload_path = "src/fixtures/hooks/claude_post_tool_batch.json" },
                .{ .args = &.{ "claude-hook", "assistant" }, .payload_path = "src/fixtures/hooks/claude_stop.json" },
            },
        },
        .{
            .origin = "codex",
            .steps = &.{
                .{ .args = &.{"codex-hook"}, .payload_path = "src/fixtures/hooks/codex_user_prompt.json" },
                .{ .args = &.{"codex-hook"}, .payload_path = "src/fixtures/hooks/codex_post_tool_use.json" },
                .{ .args = &.{"codex-hook"}, .payload_path = "src/fixtures/hooks/codex_stop.json" },
            },
        },
        .{
            .origin = "copilot",
            .steps = &.{
                .{ .args = &.{"copilot-hook"}, .payload_path = "src/fixtures/hooks/copilot_user_prompt.json" },
                .{ .args = &.{"copilot-hook"}, .payload_path = "src/fixtures/hooks/copilot_post_tool_use.json" },
                .{ .args = &.{"copilot-hook"}, .payload_path = "src/fixtures/hooks/copilot_stop.json" },
            },
        },
        .{
            .origin = "gemini",
            .steps = &.{
                .{ .args = &.{"gemini-hook"}, .payload_path = "src/fixtures/hooks/gemini_after_tool.json" },
                .{ .args = &.{"gemini-hook"}, .payload_path = "src/fixtures/hooks/gemini_after_agent.json" },
            },
        },
        .{
            .origin = "pi",
            .steps = &.{
                .{ .args = &.{"pi-hook"}, .payload_path = "src/fixtures/hooks/pi_input.json" },
                .{ .args = &.{"pi-hook"}, .payload_path = "src/fixtures/hooks/pi_tool_execution_end.json" },
                .{ .args = &.{"pi-hook"}, .payload_path = "src/fixtures/hooks/pi_agent_end.json" },
            },
        },
    };

    for (cases) |scenario| {
        var sandbox = try harness.Sandbox.init(std.testing.allocator);
        defer sandbox.deinit();
        try sandbox.writeRepoFile(".agit/.keep", "");

        for (scenario.steps) |step| {
            const payload = try std.Io.Dir.cwd().readFileAlloc(sandbox.io, step.payload_path, std.testing.allocator, .unlimited);
            defer std.testing.allocator.free(payload);

            var res = try sandbox.run(step.args, payload);
            defer res.deinit(std.testing.allocator);
            try std.testing.expectEqual(@as(u8, 0), res.exit_code);
        }

        var sessions = try sandbox.run(&.{"sessions"}, null);
        defer sessions.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, sessions.stdout, scenario.origin) != null);
    }
}

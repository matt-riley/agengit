const std = @import("std");
const hook = @import("../../hook.zig");
const adapter_mod = @import("../Adapter.zig");
const payload_mod = @import("../payload.zig");

pub const adapter: adapter_mod.Adapter = .{
    .name = "gemini-hook",
    .origin = "gemini",
    .events = &.{
        .{ .name = "AfterTool", .kind = .tool_use },
        .{ .name = "AfterAgent", .kind = .assistant },
    },
    .parsePayload = parsePayload,
    .buildStep = buildStep,
};

fn parsePayload(
    arena: std.mem.Allocator,
    payload: *const hook.Payload,
    route: []const u8,
    diagnostic: *hook.Diagnostic,
) !adapter_mod.ParsedPayload {
    _ = arena;
    _ = route;
    const root = try hook.requireObject(payload.parsed.value, diagnostic);
    return .{
        .root = root,
        .route = try hook.requireString(root, "hook_event_name", diagnostic),
    };
}

fn buildStep(
    arena: std.mem.Allocator,
    parsed: adapter_mod.ParsedPayload,
    diagnostic: *hook.Diagnostic,
) !adapter_mod.BuildPlan {
    const workspace_cwd = try hook.requireString(parsed.root, "cwd", diagnostic);
    const preferred_turn_id = try hook.optionalString(parsed.root, "turn_id", diagnostic);

    if (std.mem.eql(u8, parsed.route, "AfterTool")) {
        return .{
            .expected_event_name = "AfterTool",
            .kind = .tool_use,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "tool_use_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .records = try adapter_mod.singleRecord(arena, .{
                .tool_use = try payload_mod.toolUseFromObject(arena, parsed.root, .{ .object = parsed.root }),
            }),
        };
    }
    if (std.mem.eql(u8, parsed.route, "AfterAgent")) {
        const content = (try hook.optionalString(parsed.root, "response", diagnostic)) orelse "";
        return .{
            .expected_event_name = "AfterAgent",
            .kind = .assistant,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "event_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .records = try adapter_mod.singleRecord(arena, .{ .assistant = content }),
        };
    }

    diagnostic.* = hook.Diagnostic.unknownEvent();
    return error.UnknownEventName;
}

test "build gemini after tool fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/gemini_after_tool.json"));
    var payload = switch (payload_result) {
        .ok => |value| value,
        .err => return error.InvalidPayload,
    };
    defer payload.deinit(gpa);

    var diagnostic: hook.Diagnostic = .{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try adapter.parsePayload.?(arena, &payload, "", &diagnostic);
    const plan = try adapter.buildStep.?(arena, parsed, &diagnostic);
    try std.testing.expectEqualStrings("AfterTool", plan.expected_event_name);
    try std.testing.expect(plan.kind == .tool_use);
    try std.testing.expectEqualStrings("read_file", plan.records[0].tool_use.tool_name);
}

test "build gemini after agent fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/gemini_after_agent.json"));
    var payload = switch (payload_result) {
        .ok => |value| value,
        .err => return error.InvalidPayload,
    };
    defer payload.deinit(gpa);

    var diagnostic: hook.Diagnostic = .{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try adapter.parsePayload.?(arena, &payload, "", &diagnostic);
    const plan = try adapter.buildStep.?(arena, parsed, &diagnostic);
    try std.testing.expectEqualStrings("AfterAgent", plan.expected_event_name);
    try std.testing.expect(plan.kind == .assistant);
    try std.testing.expect(plan.records[0].assistant.len > 0);
}

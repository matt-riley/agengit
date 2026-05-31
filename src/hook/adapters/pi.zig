const std = @import("std");
const hook = @import("../../hook.zig");
const adapter_mod = @import("../Adapter.zig");
const payload_mod = @import("../payload.zig");

/// Pi integration. Unlike the JSON-config agents, Pi has no native command-hook
/// config: `agit init` installs a generated JS extension (see
/// `src/cli/pi_extension.zig`) that subscribes to Pi events and shells out to
/// `agit pi-hook` with a normalized payload. Because agit controls that payload
/// shape, this adapter is a thin router over the shared helpers.
pub const adapter: adapter_mod.Adapter = .{
    .name = "pi-hook",
    .origin = "pi",
    .events = &.{
        .{ .name = "input", .kind = .user_prompt },
        .{ .name = "tool_execution_end", .kind = .tool_use },
        .{ .name = "agent_end", .kind = .assistant },
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

    if (std.mem.eql(u8, parsed.route, "input")) {
        const prompt = try hook.requireString(parsed.root, "prompt", diagnostic);
        return .{
            .expected_event_name = "input",
            .kind = .user_prompt,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "event_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .records = try adapter_mod.singleRecord(arena, .{ .user_prompt = prompt }),
        };
    }
    if (std.mem.eql(u8, parsed.route, "tool_execution_end")) {
        return .{
            .expected_event_name = "tool_execution_end",
            .kind = .tool_use,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "tool_use_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .records = try adapter_mod.singleRecord(arena, .{
                .tool_use = try payload_mod.toolUseFromObject(arena, parsed.root, .{ .object = parsed.root }),
            }),
        };
    }
    if (std.mem.eql(u8, parsed.route, "agent_end")) {
        const content = (try hook.optionalString(parsed.root, "response", diagnostic)) orelse "";
        return .{
            .expected_event_name = "agent_end",
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

test "build pi input fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/pi_input.json"));
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
    try std.testing.expectEqualStrings("input", plan.expected_event_name);
    try std.testing.expect(plan.kind == .user_prompt);
    try std.testing.expect(plan.records[0].user_prompt.len > 0);
    try std.testing.expectEqualStrings("agturn:pi-1", plan.preferred_turn_id.?);
}

test "build pi tool execution end fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/pi_tool_execution_end.json"));
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
    try std.testing.expectEqualStrings("tool_execution_end", plan.expected_event_name);
    try std.testing.expect(plan.kind == .tool_use);
    try std.testing.expectEqualStrings("bash", plan.records[0].tool_use.tool_name);
}

test "build pi agent end fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/pi_agent_end.json"));
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
    try std.testing.expectEqualStrings("agent_end", plan.expected_event_name);
    try std.testing.expect(plan.kind == .assistant);
    try std.testing.expect(plan.records[0].assistant.len > 0);
}

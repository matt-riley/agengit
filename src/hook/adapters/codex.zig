const std = @import("std");
const hook = @import("../../hook.zig");
const adapter_mod = @import("../Adapter.zig");
const payload_mod = @import("../payload.zig");

pub const adapter: adapter_mod.Adapter = .{
    .name = "codex-hook",
    .origin = "codex",
    .events = &.{
        .{ .name = "UserPromptSubmit", .kind = .user_prompt },
        .{ .name = "PostToolUse", .kind = .tool_use },
        .{ .name = "Stop", .kind = .assistant },
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
    const model = try hook.optionalString(parsed.root, "model", diagnostic);

    if (std.mem.eql(u8, parsed.route, "UserPromptSubmit")) {
        const prompt = try hook.requireString(parsed.root, "prompt", diagnostic);
        return .{
            .expected_event_name = "UserPromptSubmit",
            .kind = .user_prompt,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "event_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .model = model,
            .records = try adapter_mod.singleRecord(arena, .{ .user_prompt = prompt }),
        };
    }
    if (std.mem.eql(u8, parsed.route, "PostToolUse")) {
        return .{
            .expected_event_name = "PostToolUse",
            .kind = .tool_use,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "tool_use_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .model = model,
            .records = try adapter_mod.singleRecord(arena, .{
                .tool_use = try payload_mod.toolUseFromObject(arena, parsed.root, .{ .object = parsed.root }),
            }),
        };
    }
    if (std.mem.eql(u8, parsed.route, "Stop")) {
        const content = (try hook.optionalString(parsed.root, "last_assistant_message", diagnostic)) orelse "";
        return .{
            .expected_event_name = "Stop",
            .kind = .assistant,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "event_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .model = model,
            .records = try adapter_mod.singleRecord(arena, .{ .assistant = content }),
        };
    }

    diagnostic.* = hook.Diagnostic.unknownEvent();
    return error.UnknownEventName;
}

test "codex malformed tool event records unknown placeholder" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa,
        \\{
        \\  "session_id": "codex-sess-001",
        \\  "cwd": "/repo",
        \\  "hook_event_name": "PostToolUse",
        \\  "tool_input": {"command": "true"}
        \\}
    );
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
    try std.testing.expect(plan.kind == .tool_use);
    try std.testing.expectEqualStrings("unknown", plan.records[0].tool_use.tool_name);
    try std.testing.expectEqualStrings("missing tool_name", plan.records[0].tool_use.result);
}

test "build codex user prompt fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/codex_user_prompt.json"));
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
    try std.testing.expectEqualStrings("UserPromptSubmit", plan.expected_event_name);
    try std.testing.expect(plan.kind == .user_prompt);
    try std.testing.expect(plan.records[0].user_prompt.len > 0);
}

test "build codex post tool use fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/codex_post_tool_use.json"));
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
    try std.testing.expectEqualStrings("PostToolUse", plan.expected_event_name);
    try std.testing.expect(plan.kind == .tool_use);
    try std.testing.expectEqualStrings("bash", plan.records[0].tool_use.tool_name);
}

test "build codex stop fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/codex_stop.json"));
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
    try std.testing.expectEqualStrings("Stop", plan.expected_event_name);
    try std.testing.expect(plan.kind == .assistant);
    try std.testing.expect(plan.records[0].assistant.len > 0);
}

test "codex hook plan carries top-level model when present" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa,
        \\{
        \\  "session_id": "codex-sess-001",
        \\  "turn_id": "turn-1",
        \\  "cwd": "/repo",
        \\  "hook_event_name": "Stop",
        \\  "model": "gpt-5-codex",
        \\  "last_assistant_message": "done"
        \\}
    );
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
    try std.testing.expectEqualStrings("gpt-5-codex", plan.model.?);
}

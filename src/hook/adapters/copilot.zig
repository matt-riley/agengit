const std = @import("std");
const hook = @import("../../hook.zig");
const adapter_mod = @import("../Adapter.zig");
const payload_mod = @import("../payload.zig");

pub const adapter: adapter_mod.Adapter = .{
    .name = "copilot-hook",
    .origin = "copilot",
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

    if (std.mem.eql(u8, parsed.route, "UserPromptSubmit")) {
        const prompt = try hook.requireString(parsed.root, "prompt", diagnostic);
        return .{
            .expected_event_name = "UserPromptSubmit",
            .kind = .user_prompt,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "event_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
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
            .records = try adapter_mod.singleRecord(arena, .{
                .tool_use = try toolUse(arena, parsed.root),
            }),
        };
    }
    if (std.mem.eql(u8, parsed.route, "Stop")) {
        // Copilot's Stop payload carries no inline assistant text; record empty.
        return .{
            .expected_event_name = "Stop",
            .kind = .assistant,
            .workspace_cwd = workspace_cwd,
            .source_event_id = try hook.optionalString(parsed.root, "event_id", diagnostic),
            .preferred_turn_id = preferred_turn_id,
            .records = try adapter_mod.singleRecord(arena, .{ .assistant = "" }),
        };
    }

    diagnostic.* = hook.Diagnostic.unknownEvent();
    return error.UnknownEventName;
}

/// Copilot's PostToolUse payload nests the result under `tool_result` (an
/// object) rather than the flat `tool_response` field the shared helper reads.
/// Prefer `tool_result.text_result_for_llm`, falling back to the stringified
/// object so malformed payloads stay observable.
fn toolUse(arena: std.mem.Allocator, root: std.json.ObjectMap) !adapter_mod.ToolUse {
    const tool_name = switch (root.get("tool_name") orelse std.json.Value.null) {
        .string => |s| s,
        else => "unknown",
    };

    const tool_input_val = root.get("tool_input") orelse std.json.Value.null;
    const args = try payload_mod.stringifyValue(arena, tool_input_val);

    const result: []const u8 = blk: {
        const tool_result_val = root.get("tool_result") orelse break :blk "";
        switch (tool_result_val) {
            .object => |obj| {
                if (obj.get("text_result_for_llm")) |text_val| {
                    if (text_val == .string) break :blk text_val.string;
                }
                break :blk try payload_mod.stringifyValue(arena, tool_result_val);
            },
            .string => |s| break :blk s,
            else => break :blk try payload_mod.stringifyValue(arena, tool_result_val),
        }
    };

    return .{
        .tool_name = tool_name,
        .args = args,
        .result = result,
    };
}

test "build copilot user prompt fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/copilot_user_prompt.json"));
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

test "build copilot post tool use fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/copilot_post_tool_use.json"));
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
    try std.testing.expect(std.mem.indexOf(u8, plan.records[0].tool_use.result, "hashlib") != null);
}

test "copilot tool use without tool_result records empty result" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa,
        \\{
        \\  "session_id": "copilot-sess-001",
        \\  "cwd": "/repo",
        \\  "hook_event_name": "PostToolUse",
        \\  "tool_name": "read",
        \\  "tool_input": {"path": "a.txt"}
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
    try std.testing.expectEqualStrings("read", plan.records[0].tool_use.tool_name);
    try std.testing.expectEqualStrings("", plan.records[0].tool_use.result);
}

test "build copilot stop fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/copilot_stop.json"));
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
    try std.testing.expectEqualStrings("", plan.records[0].assistant);
}

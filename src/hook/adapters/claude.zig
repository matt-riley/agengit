const std = @import("std");
const hook = @import("../../hook.zig");
const adapter_mod = @import("../Adapter.zig");
const payload_mod = @import("../payload.zig");

pub const hook_adapter: adapter_mod.Adapter = .{
    .name = "claude-hook",
    .origin = "claude",
    .events = &.{
        .{ .name = "SessionStart", .kind = .metadata },
        .{ .name = "UserPromptSubmit", .kind = .user_prompt },
        .{ .name = "Stop", .kind = .assistant },
    },
    .parseArgs = parseHookArgs,
    .parsePayload = parsePayload,
    .buildStep = buildHookStep,
};

pub const tool_batch_adapter: adapter_mod.Adapter = .{
    .name = "claude-tool-batch-hook",
    .origin = "claude",
    .events = &.{
        .{ .name = "PostToolBatch", .kind = .tool_use },
    },
    .parsePayload = parsePayload,
    .buildStep = buildToolBatchStep,
};

fn parseHookArgs(iter: *std.process.Args.Iterator, diagnostic: *hook.Diagnostic) ![]const u8 {
    const subcommand = iter.next() orelse {
        diagnostic.* = .{
            .code = "missing_subcommand",
            .message = "claude hook subcommand is required",
        };
        return error.MissingSubcommand;
    };
    if (std.mem.eql(u8, subcommand, "user") or std.mem.eql(u8, subcommand, "assistant") or std.mem.eql(u8, subcommand, "session-start")) {
        return subcommand;
    }

    diagnostic.* = .{
        .code = "unknown_subcommand",
        .message = "claude hook subcommand is unknown",
    };
    return error.UnknownSubcommand;
}

fn parsePayload(
    arena: std.mem.Allocator,
    payload: *const hook.Payload,
    route: []const u8,
    diagnostic: *hook.Diagnostic,
) !adapter_mod.ParsedPayload {
    _ = arena;
    return .{
        .root = try hook.requireObject(payload.parsed.value, diagnostic),
        .route = if (route.len > 0) route else "tool-batch",
    };
}

fn buildHookStep(
    arena: std.mem.Allocator,
    parsed: adapter_mod.ParsedPayload,
    diagnostic: *hook.Diagnostic,
) !adapter_mod.BuildPlan {
    const workspace_cwd = try hook.requireString(parsed.root, "cwd", diagnostic);
    const preferred_turn_id = try hook.optionalString(parsed.root, "turn_id", diagnostic);
    const source_event_id = try hook.optionalString(parsed.root, "event_id", diagnostic);
    const model = try hook.optionalString(parsed.root, "model", diagnostic);

    if (std.mem.eql(u8, parsed.route, "session-start")) {
        return .{
            .expected_event_name = "SessionStart",
            .kind = .metadata,
            .workspace_cwd = workspace_cwd,
            .source_event_id = source_event_id,
            .preferred_turn_id = preferred_turn_id,
            .model = model,
            .records = &.{},
        };
    }

    if (std.mem.eql(u8, parsed.route, "user")) {
        const prompt = try hook.requireString(parsed.root, "prompt", diagnostic);
        return .{
            .expected_event_name = "UserPromptSubmit",
            .kind = .user_prompt,
            .workspace_cwd = workspace_cwd,
            .source_event_id = source_event_id,
            .preferred_turn_id = preferred_turn_id,
            .model = model,
            .records = try adapter_mod.singleRecord(arena, .{ .user_prompt = prompt }),
        };
    }
    if (std.mem.eql(u8, parsed.route, "assistant")) {
        const content = (try hook.optionalString(parsed.root, "last_assistant_message", diagnostic)) orelse "";
        return .{
            .expected_event_name = "Stop",
            .kind = .assistant,
            .workspace_cwd = workspace_cwd,
            .source_event_id = source_event_id,
            .preferred_turn_id = preferred_turn_id,
            .model = model,
            .records = try adapter_mod.singleRecord(arena, .{ .assistant = content }),
        };
    }

    diagnostic.* = .{
        .code = "unknown_subcommand",
        .message = "claude hook subcommand is unknown",
    };
    return error.UnknownSubcommand;
}

fn buildToolBatchStep(
    arena: std.mem.Allocator,
    parsed: adapter_mod.ParsedPayload,
    diagnostic: *hook.Diagnostic,
) !adapter_mod.BuildPlan {
    const workspace_cwd = try hook.requireString(parsed.root, "cwd", diagnostic);
    const preferred_turn_id = try hook.optionalString(parsed.root, "turn_id", diagnostic);

    const tool_calls_val = parsed.root.get("tool_calls") orelse {
        diagnostic.* = hook.Diagnostic.missing("tool_calls");
        return error.MissingRequiredField;
    };
    const tool_calls = switch (tool_calls_val) {
        .array => |value| value,
        else => {
            diagnostic.* = hook.Diagnostic.invalid("tool_calls");
            return error.InvalidFieldType;
        },
    };

    const records = try arena.alloc(adapter_mod.Record, tool_calls.items.len);
    for (tool_calls.items, 0..) |tool_call, i| {
        records[i] = .{
            .tool_use = try payload_mod.toolUseFromValue(arena, tool_call, "tool entry is not an object"),
        };
    }

    return .{
        .expected_event_name = "PostToolBatch",
        .kind = .tool_use,
        .workspace_cwd = workspace_cwd,
        .preferred_turn_id = preferred_turn_id,
        .records = records,
    };
}

test "build claude user fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/claude_user_prompt.json"));
    var payload = switch (payload_result) {
        .ok => |value| value,
        .err => return error.InvalidPayload,
    };
    defer payload.deinit(gpa);

    var diagnostic: hook.Diagnostic = .{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try hook_adapter.parsePayload.?(arena, &payload, "user", &diagnostic);
    const plan = try hook_adapter.buildStep.?(arena, parsed, &diagnostic);
    try std.testing.expectEqualStrings("UserPromptSubmit", plan.expected_event_name);
    try std.testing.expect(plan.kind == .user_prompt);
    try std.testing.expectEqual(@as(usize, 1), plan.records.len);
    try std.testing.expectEqualStrings("Write a function to calculate factorial", plan.records[0].user_prompt);
}

test "build claude stop fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/claude_stop.json"));
    var payload = switch (payload_result) {
        .ok => |value| value,
        .err => return error.InvalidPayload,
    };
    defer payload.deinit(gpa);

    var diagnostic: hook.Diagnostic = .{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try hook_adapter.parsePayload.?(arena, &payload, "assistant", &diagnostic);
    const plan = try hook_adapter.buildStep.?(arena, parsed, &diagnostic);
    try std.testing.expectEqualStrings("Stop", plan.expected_event_name);
    try std.testing.expect(plan.kind == .assistant);
    try std.testing.expect(plan.records[0].assistant.len > 0);
}

test "build claude tool batch fixture plan" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa, @embedFile("../../fixtures/hooks/claude_post_tool_batch.json"));
    var payload = switch (payload_result) {
        .ok => |value| value,
        .err => return error.InvalidPayload,
    };
    defer payload.deinit(gpa);

    var diagnostic: hook.Diagnostic = .{};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try tool_batch_adapter.parsePayload.?(arena, &payload, "", &diagnostic);
    const plan = try tool_batch_adapter.buildStep.?(arena, parsed, &diagnostic);
    try std.testing.expectEqualStrings("PostToolBatch", plan.expected_event_name);
    try std.testing.expect(plan.kind == .tool_use);
    try std.testing.expectEqual(@as(usize, 2), plan.records.len);
    try std.testing.expectEqualStrings("Read", plan.records[0].tool_use.tool_name);
    try std.testing.expectEqualStrings("Bash", plan.records[1].tool_use.tool_name);
}

test "build claude session start fixture captures optional model" {
    const gpa = std.testing.allocator;
    const payload_result = try hook.parsePayloadBytes(gpa,
        \\{
        \\  "session_id": "claude-sess-001",
        \\  "cwd": "/repo",
        \\  "hook_event_name": "SessionStart",
        \\  "model": "claude-sonnet-4-6"
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

    const parsed = try hook_adapter.parsePayload.?(arena, &payload, "session-start", &diagnostic);
    const plan = try hook_adapter.buildStep.?(arena, parsed, &diagnostic);
    try std.testing.expectEqualStrings("SessionStart", plan.expected_event_name);
    try std.testing.expect(plan.kind == .metadata);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", plan.model.?);
}

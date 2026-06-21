const std = @import("std");
const hook = @import("../hook.zig");
const event_mod = @import("event.zig");
const adapter_mod = @import("Adapter.zig");
const recorder_mod = @import("../recorder.zig");

const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;

/// Execute one hook adapter. Errors are always reported fail-open and then
/// swallowed so the calling agent keeps running.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, adapter: adapter_mod.Adapter) !void {
    runInner(io, gpa, iter, adapter) catch {};
}

fn runInner(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, adapter: adapter_mod.Adapter) !void {
    var diagnostic: hook.Diagnostic = .{};

    const route = parseArgs(iter, adapter, &diagnostic) catch |err| {
        hook.reportFailure(io, gpa, .{
            .agent = adapter.name,
            .err = err,
            .diagnostic = diagnostic,
        });
        return err;
    };

    const payload_result = hook.readPayload(io, gpa) catch |err| {
        if (err == error.HookPayloadTooLarge) diagnostic = hook.Diagnostic.oversized();
        hook.reportFailure(io, gpa, .{
            .agent = adapter.name,
            .err = err,
            .diagnostic = diagnostic,
            .max_payload_bytes = hook.maxHookPayloadBytes(),
        });
        return err;
    };
    var payload = switch (payload_result) {
        .ok => |ok| ok,
        .err => |parse_err| {
            var parse = parse_err;
            defer parse.deinit(gpa);
            diagnostic = hook.Diagnostic.invalidJson();
            hook.reportFailure(io, gpa, .{
                .agent = adapter.name,
                .err = error.InvalidPayload,
                .diagnostic = diagnostic,
                .payload_size = parse.raw_size,
                .payload_snippet = parse.snippet,
                .parse_path = parse.path,
                .parse_offset = parse.offset,
                .parse_line = parse.line,
                .parse_column = parse.column,
                .max_payload_bytes = hook.maxHookPayloadBytes(),
            });
            return error.InvalidPayload;
        },
    };
    defer payload.deinit(gpa);

    processPayload(io, gpa, adapter, route, &payload, &diagnostic) catch |err| {
        switch (err) {
            error.LockTimeout => diagnostic = hook.Diagnostic.lockTimeout(),
            error.InvalidAdapter => diagnostic = .{
                .code = "invalid_adapter",
                .message = "hook adapter is misconfigured",
            },
            else => {},
        }
        hook.reportFailure(io, gpa, .{
            .agent = adapter.name,
            .err = err,
            .diagnostic = diagnostic,
            .session_id = payload.session_id,
            .event_name = payload.event_name,
            .payload = payload.raw,
            .max_payload_bytes = hook.maxHookPayloadBytes(),
            .workspace_cwd = payload.cwd,
        });
        return err;
    };
}

fn parseArgs(iter: *std.process.Args.Iterator, adapter: adapter_mod.Adapter, diagnostic: *hook.Diagnostic) ![]const u8 {
    const parse = adapter.parseArgs orelse adapter_mod.parseNoArgs;
    return parse(iter, diagnostic);
}

fn processPayload(
    io: std.Io,
    gpa: std.mem.Allocator,
    adapter: adapter_mod.Adapter,
    route: []const u8,
    payload: *const hook.Payload,
    diagnostic: *hook.Diagnostic,
) !void {
    const parse_payload = adapter.parsePayload orelse return error.InvalidAdapter;
    const build_step = adapter.buildStep orelse return error.InvalidAdapter;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parse_payload(arena, payload, route, diagnostic);
    const plan = try build_step(arena, parsed, diagnostic);

    if (!adapter_mod.declaresEvent(adapter, plan.expected_event_name, plan.kind)) {
        diagnostic.* = hook.Diagnostic.unknownEvent();
        return error.UnknownEventName;
    }
    if (plan.records.len == 0 and plan.kind != .metadata) return;

    var workspace = try event_mod.openWorkspaceDir(io, plan.workspace_cwd);
    defer workspace.dir.close(io);

    var rec = try Recorder.open(io, workspace.dir, gpa);
    defer rec.deinit(io);
    if (!rec.originEnabled(adapter.origin)) return;

    var normalized = try event_mod.normalize(io, gpa, &rec, parsed.root, diagnostic, .{
        .origin = adapter.origin,
        .expected_event_name = plan.expected_event_name,
        .kind = plan.kind,
        .source_event_id = plan.source_event_id,
        .preferred_turn_id = plan.preferred_turn_id,
    });
    defer normalized.deinit(io, gpa);

    if (workspace.used_fallback) {
        rec.logHookFailure(io, adapter.name, error.InvalidCwd, .{
            .agent = adapter.name,
            .code = "workspace_cwd_fallback",
            .message = "payload cwd could not be opened; used hook process cwd fallback",
            .session_id = normalized.session_id,
            .event_name = normalized.event_name,
        });
    }

    if (normalized.recovered_turn) {
        const recovery_message = switch (plan.kind) {
            .tool_use => "tool event arrived without an active turn; generated recovery turn id",
            .assistant => "assistant event arrived without an active turn; generated recovery turn id",
            .user_prompt => null,
            .metadata => null,
        };
        if (recovery_message) |message| {
            rec.logHookFailure(io, adapter.name, error.MissingActiveTurn, .{
                .agent = adapter.name,
                .code = "recovery_turn_id",
                .message = message,
                .session_id = normalized.session_id,
                .event_name = normalized.event_name,
            });
        }
    }

    const meta: SessionMeta = .{
        .origin = normalized.origin,
        .session_id = normalized.session_id,
    };
    try rec.upsertSession(meta);

    if (plan.model) |model| {
        if (normalized.turn_id.len > 0) {
            try rec.recordTurnModel(io, meta, normalized.turn_id, model);
        } else {
            try rec.recordSessionModel(meta, model);
        }
    }

    switch (plan.kind) {
        .metadata => return,
        .user_prompt => {
            if (plan.records.len != 1) return error.InvalidAdapter;
            const content = switch (plan.records[0]) {
                .user_prompt => |value| value,
                else => return error.InvalidAdapter,
            };
            try rec.recordUserPrompt(io, meta, normalized.turn_id, .{ .content = content });
        },
        .tool_use => {
            for (plan.records) |record| {
                const tool = switch (record) {
                    .tool_use => |value| value,
                    else => return error.InvalidAdapter,
                };
                try rec.recordToolUse(io, meta, normalized.turn_id, .{
                    .tool_name = tool.tool_name,
                    .args = tool.args,
                    .result = tool.result,
                });
            }
        },
        .assistant => {
            if (plan.records.len != 1) return error.InvalidAdapter;
            const content = switch (plan.records[0]) {
                .assistant => |value| value,
                else => return error.InvalidAdapter,
            };
            try rec.recordAssistantAndFinalize(io, meta, normalized.turn_id, .{ .content = content }, &.{});
        },
    }
}

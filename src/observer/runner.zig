const std = @import("std");
const checkpoint_mod = @import("checkpoint.zig");
const source_mod = @import("Source.zig");
const event_mod = @import("../hook/event.zig");
const recorder_mod = @import("../recorder.zig");

const Recorder = recorder_mod.Recorder;
const SessionMeta = recorder_mod.SessionMeta;

pub const Summary = struct {
    processed_events: usize = 0,
    prompts: usize = 0,
    tool_calls: usize = 0,
    finalized_turns: usize = 0,
    skipped_disabled_events: usize = 0,
};

pub fn runOnce(
    io: std.Io,
    gpa: std.mem.Allocator,
    rec: *Recorder,
    source: source_mod.Source,
    options: source_mod.Options,
) !Summary {
    var checkpoint = try checkpoint_mod.load(io, rec.store.root, gpa, source.name);
    defer checkpoint.deinit(gpa);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const load_result = try source.loadEvents(arena, io, options, checkpoint);

    if (checkpoint.instance_id) |existing| {
        const next_instance = load_result.instance_id orelse return error.ObserverCheckpointInstanceMismatch;
        if (!std.mem.eql(u8, existing, next_instance)) return error.ObserverCheckpointInstanceMismatch;
    }

    var summary: Summary = .{};
    for (load_result.events) |observer_event| {
        if (observer_event.watermark.len == 0) return error.InvalidObserverEvent;
        if (observer_event.records.len == 0) return error.InvalidObserverEvent;

        if (!rec.originEnabled(observer_event.origin)) {
            try updateCheckpoint(io, gpa, rec, source.name, &checkpoint, load_result.instance_id, observer_event.watermark);
            summary.skipped_disabled_events += 1;
            continue;
        }

        var normalized = try event_mod.normalizeResolved(io, gpa, rec, .{
            .origin = observer_event.origin,
            .session_id = observer_event.session_id,
            .workspace_cwd = observer_event.workspace_cwd,
            .event_name = observer_event.event_name,
            .kind = observer_event.kind,
            .source_event_id = observer_event.source_event_id,
            .preferred_turn_id = observer_event.preferred_turn_id,
        });
        defer normalized.deinit(io, gpa);

        if (normalized.recovered_turn) {
            const recovery_message = switch (observer_event.kind) {
                .tool_use => "observer tool event arrived without an active turn; generated recovery turn id",
                .assistant => "observer assistant event arrived without an active turn; generated recovery turn id",
                .user_prompt => null,
            };
            if (recovery_message) |message| {
                rec.logHookFailure(io, source.name, error.MissingActiveTurn, .{
                    .agent = source.name,
                    .code = "observer_recovery_turn_id",
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

        switch (observer_event.kind) {
            .user_prompt => {
                if (observer_event.records.len != 1) return error.InvalidObserverEvent;
                const prompt = switch (observer_event.records[0]) {
                    .user_prompt => |value| value,
                    else => return error.InvalidObserverEvent,
                };
                try rec.recordUserPrompt(io, meta, normalized.turn_id, .{ .content = prompt });
                summary.prompts += 1;
            },
            .tool_use => {
                for (observer_event.records) |record| {
                    const tool = switch (record) {
                        .tool_use => |value| value,
                        else => return error.InvalidObserverEvent,
                    };
                    try rec.recordToolUse(io, meta, normalized.turn_id, .{
                        .tool_name = tool.tool_name,
                        .args = tool.args,
                        .result = tool.result,
                    });
                    summary.tool_calls += 1;
                }
            },
            .assistant => {
                if (observer_event.records.len != 1) return error.InvalidObserverEvent;
                const assistant = switch (observer_event.records[0]) {
                    .assistant => |value| value,
                    else => return error.InvalidObserverEvent,
                };
                try rec.recordAssistantAndFinalize(io, meta, normalized.turn_id, .{ .content = assistant }, observer_event.causes);
                summary.finalized_turns += 1;
            },
        }

        try updateCheckpoint(io, gpa, rec, source.name, &checkpoint, load_result.instance_id, observer_event.watermark);
        summary.processed_events += 1;
    }

    return summary;
}

fn updateCheckpoint(
    io: std.Io,
    gpa: std.mem.Allocator,
    rec: *Recorder,
    source_name: []const u8,
    checkpoint: *checkpoint_mod.Checkpoint,
    instance_id: ?[]const u8,
    watermark: []const u8,
) !void {
    try checkpoint_mod.replaceField(gpa, &checkpoint.instance_id, instance_id);
    try checkpoint_mod.replaceField(gpa, &checkpoint.watermark, watermark);
    try checkpoint_mod.save(io, rec.store.root, gpa, source_name, checkpoint.*);
}

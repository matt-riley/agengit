const std = @import("std");
const checkpoint_mod = @import("checkpoint.zig");
const event_mod = @import("../hook/event.zig");
const adapter_mod = @import("../hook/Adapter.zig");
const recorder_mod = @import("../recorder.zig");

pub const Record = adapter_mod.Record;
pub const ToolUse = adapter_mod.ToolUse;

pub const Options = struct {
    input_path: ?[]const u8 = null,
};

pub const Event = struct {
    origin: []const u8,
    session_id: []const u8,
    workspace_cwd: []const u8,
    event_name: []const u8,
    kind: event_mod.EventKind,
    watermark: []const u8,
    source_event_id: ?[]const u8 = null,
    preferred_turn_id: ?[]const u8 = null,
    records: []const Record,
    causes: []const recorder_mod.Cause = &.{},
};

pub const LoadResult = struct {
    instance_id: ?[]const u8 = null,
    events: []const Event = &.{},
};

pub const Source = struct {
    name: []const u8,
    summary: []const u8,
    experimental: bool = true,
    loadEvents: *const fn (
        arena: std.mem.Allocator,
        io: std.Io,
        options: Options,
        checkpoint: checkpoint_mod.Checkpoint,
    ) anyerror!LoadResult,
};

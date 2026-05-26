const std = @import("std");
const hook = @import("../hook.zig");
const event_mod = @import("event.zig");

/// Declares one hook event name that an adapter can normalize into a recorder step.
pub const EventMapping = struct {
    name: []const u8,
    kind: event_mod.EventKind,
};

/// A recorder-ready tool use entry.
pub const ToolUse = struct {
    tool_name: []const u8,
    args: []const u8,
    result: []const u8,
};

/// A recorder-ready record emitted by an adapter build step.
pub const Record = union(enum) {
    user_prompt: []const u8,
    tool_use: ToolUse,
    assistant: []const u8,
};

/// Adapter-owned parse result.
///
/// `root` borrows from the GPA-owned `hook.Payload`; use the arena only for
/// derived strings and slices that live for the duration of one runner call.
pub const ParsedPayload = struct {
    root: std.json.ObjectMap,
    route: []const u8,
};

/// Runner-owned execution plan emitted by an adapter build step.
pub const BuildPlan = struct {
    expected_event_name: []const u8,
    kind: event_mod.EventKind,
    workspace_cwd: []const u8,
    source_event_id: ?[]const u8 = null,
    preferred_turn_id: ?[]const u8 = null,
    records: []const Record,
};

/// Hook adapter contract used by `src/hook/runner.zig`.
///
/// `parseArgs` runs before any payload bytes are read so CLI-routing errors can
/// fail cleanly without payload context. `parsePayload` inspects the parsed JSON
/// payload and returns adapter-specific routing information. `buildStep`
/// transforms that parse result into one or more recorder-ready records.
pub const Adapter = struct {
    name: []const u8,
    origin: []const u8,
    events: []const EventMapping,
    parseArgs: ?*const fn (iter: *std.process.Args.Iterator, diagnostic: *hook.Diagnostic) anyerror![]const u8 = null,
    parsePayload: ?*const fn (arena: std.mem.Allocator, payload: *const hook.Payload, route: []const u8, diagnostic: *hook.Diagnostic) anyerror!ParsedPayload,
    buildStep: ?*const fn (arena: std.mem.Allocator, parsed: ParsedPayload, diagnostic: *hook.Diagnostic) anyerror!BuildPlan,
};

pub fn parseNoArgs(iter: *std.process.Args.Iterator, diagnostic: *hook.Diagnostic) ![]const u8 {
    _ = iter;
    _ = diagnostic;
    return "";
}

pub fn singleRecord(arena: std.mem.Allocator, record: Record) ![]const Record {
    const records = try arena.alloc(Record, 1);
    records[0] = record;
    return records;
}

pub fn declaresEvent(adapter: Adapter, expected_event_name: []const u8, kind: event_mod.EventKind) bool {
    for (adapter.events) |event| {
        if (std.mem.eql(u8, event.name, expected_event_name) and event.kind == kind) return true;
    }
    return false;
}

test "declaresEvent matches registered events" {
    const adapter: Adapter = .{
        .name = "example-hook",
        .origin = "example",
        .events = &.{
            .{ .name = "UserPromptSubmit", .kind = .user_prompt },
            .{ .name = "Stop", .kind = .assistant },
        },
        .parsePayload = null,
        .buildStep = null,
    };

    try std.testing.expect(declaresEvent(adapter, "UserPromptSubmit", .user_prompt));
    try std.testing.expect(!declaresEvent(adapter, "PostToolUse", .tool_use));
}

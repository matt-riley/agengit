const std = @import("std");
const source_mod = @import("../Source.zig");
const checkpoint_mod = @import("../checkpoint.zig");
const event_mod = @import("../../hook/event.zig");

const max_fixture_bytes = std.Io.Limit.limited(4 * 1024 * 1024);

const FixtureFile = struct {
    events: []const EventDisk = &.{},
};

const EventDisk = struct {
    watermark: []const u8,
    origin: []const u8 = "fixture",
    session_id: []const u8,
    cwd: []const u8,
    event_name: []const u8,
    kind: event_mod.EventKind,
    source_event_id: ?[]const u8 = null,
    preferred_turn_id: ?[]const u8 = null,
    records: []const RecordDisk,
};

const RecordDisk = struct {
    type: enum {
        user_prompt,
        tool_use,
        assistant,
    },
    content: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    args: ?[]const u8 = null,
    result: ?[]const u8 = null,
};

pub const source: source_mod.Source = .{
    .name = "fixture",
    .summary = "Read deterministic observer events from a JSON fixture file.",
    .loadEvents = loadEvents,
};

fn loadEvents(
    arena: std.mem.Allocator,
    io: std.Io,
    options: source_mod.Options,
    checkpoint: checkpoint_mod.Checkpoint,
) !source_mod.LoadResult {
    const input_path = options.input_path orelse return error.ObserverInputRequired;
    const instance_id = try resolveInputPath(arena, io, input_path);

    if (checkpoint.instance_id) |existing| {
        if (!std.mem.eql(u8, existing, instance_id)) return error.ObserverCheckpointInstanceMismatch;
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, input_path, arena, max_fixture_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.ObserverInputTooLarge,
        else => return err,
    };

    var parsed = try std.json.parseFromSlice(FixtureFile, arena, raw, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var seen = std.StringHashMap(void).init(arena);
    var checkpoint_index: ?usize = null;
    for (parsed.value.events, 0..) |event, index| {
        if (event.watermark.len == 0 or event.session_id.len == 0 or event.cwd.len == 0 or event.event_name.len == 0) {
            return error.InvalidObserverEvent;
        }
        if (seen.contains(event.watermark)) return error.DuplicateObserverWatermark;
        try seen.put(event.watermark, {});
        if (checkpoint.watermark) |watermark| {
            if (std.mem.eql(u8, watermark, event.watermark)) checkpoint_index = index;
        }
    }

    if (checkpoint.watermark != null and checkpoint_index == null) return error.ObserverWatermarkNotFound;
    const start_index = if (checkpoint_index) |index| index + 1 else 0;
    const input_events = parsed.value.events[start_index..];

    const events = try arena.alloc(source_mod.Event, input_events.len);
    for (input_events, 0..) |event, index| {
        events[index] = .{
            .origin = event.origin,
            .session_id = event.session_id,
            .workspace_cwd = event.cwd,
            .event_name = event.event_name,
            .kind = event.kind,
            .watermark = event.watermark,
            .source_event_id = event.source_event_id,
            .preferred_turn_id = event.preferred_turn_id,
            .records = try convertRecords(arena, event.records),
        };
    }

    return .{
        .instance_id = instance_id,
        .events = events,
    };
}

fn resolveInputPath(arena: std.mem.Allocator, io: std.Io, input_path: []const u8) ![]u8 {
    _ = io;
    if (std.fs.path.isAbsolute(input_path)) return try arena.dupe(u8, input_path);
    return std.fs.path.resolve(arena, &.{ ".", input_path });
}

fn convertRecords(arena: std.mem.Allocator, input: []const RecordDisk) ![]const source_mod.Record {
    const records = try arena.alloc(source_mod.Record, input.len);
    for (input, 0..) |record, index| {
        records[index] = switch (record.type) {
            .user_prompt => .{ .user_prompt = record.content orelse return error.InvalidObserverEvent },
            .assistant => .{ .assistant = record.content orelse return error.InvalidObserverEvent },
            .tool_use => .{ .tool_use = .{
                .tool_name = record.tool_name orelse return error.InvalidObserverEvent,
                .args = record.args orelse return error.InvalidObserverEvent,
                .result = record.result orelse return error.InvalidObserverEvent,
            } },
        };
    }
    return records;
}

test "fixture source resumes after checkpoint watermark" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "observer.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{
        \\  "events": [
        \\    {
        \\      "watermark": "evt-1",
        \\      "session_id": "sess-1",
        \\      "cwd": ".",
        \\      "event_name": "UserPromptSubmit",
        \\      "kind": "user_prompt",
        \\      "records": [{ "type": "user_prompt", "content": "hello" }]
        \\    },
        \\    {
        \\      "watermark": "evt-2",
        \\      "session_id": "sess-1",
        \\      "cwd": ".",
        \\      "event_name": "Stop",
        \\      "kind": "assistant",
        \\      "records": [{ "type": "assistant", "content": "done" }]
        \\    }
        \\  ]
        \\}
    );

    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_len = try tmp.parent_dir.realPath(std.testing.io, &parent_buf);
    const real_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/observer.json",
        .{ parent_buf[0..parent_len], tmp.sub_path },
    );
    defer std.testing.allocator.free(real_path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var checkpoint: checkpoint_mod.Checkpoint = .{
        .instance_id = try std.testing.allocator.dupe(u8, real_path),
        .watermark = try std.testing.allocator.dupe(u8, "evt-1"),
    };
    defer checkpoint.deinit(std.testing.allocator);

    const result = try loadEvents(arena_state.allocator(), std.testing.io, .{ .input_path = real_path }, checkpoint);
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    try std.testing.expectEqualStrings("evt-2", result.events[0].watermark);
}

test "fixture source fails when checkpoint watermark is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "observer.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{
        \\  "events": [
        \\    {
        \\      "watermark": "evt-2",
        \\      "session_id": "sess-1",
        \\      "cwd": ".",
        \\      "event_name": "Stop",
        \\      "kind": "assistant",
        \\      "records": [{ "type": "assistant", "content": "done" }]
        \\    }
        \\  ]
        \\}
    );

    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_len = try tmp.parent_dir.realPath(std.testing.io, &parent_buf);
    const real_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/observer.json",
        .{ parent_buf[0..parent_len], tmp.sub_path },
    );
    defer std.testing.allocator.free(real_path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var checkpoint: checkpoint_mod.Checkpoint = .{
        .instance_id = try std.testing.allocator.dupe(u8, real_path),
        .watermark = try std.testing.allocator.dupe(u8, "evt-1"),
    };
    defer checkpoint.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.ObserverWatermarkNotFound,
        loadEvents(arena_state.allocator(), std.testing.io, .{ .input_path = real_path }, checkpoint),
    );
}

test "fixture source normalizes relative input paths for checkpoint identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const normalized = try resolveInputPath(arena_state.allocator(), std.testing.io, "./observer.json");
    try std.testing.expectEqualStrings("observer.json", normalized);
}

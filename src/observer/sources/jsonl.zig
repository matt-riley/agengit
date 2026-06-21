const std = @import("std");
const source_mod = @import("../Source.zig");
const checkpoint_mod = @import("../checkpoint.zig");
const event_mod = @import("../../hook/event.zig");

// ponytail: cap input at 4 MiB — matches the fixture safety cap; raise when a
// real long-tailing workflow needs streaming reads past this size.
const max_input_bytes = std.Io.Limit.limited(4 * 1024 * 1024);

/// One line of the JSONL session log. `role` maps to a Record variant:
/// user -> user_prompt, tool -> tool_use, assistant -> assistant.
const LineEvent = struct {
    session_id: []const u8,
    cwd: []const u8,
    role: Role,
    content: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    args: ?[]const u8 = null,
    result: ?[]const u8 = null,
    /// Optional override; otherwise derived from `role`.
    event_name: ?[]const u8 = null,
};

const Role = enum {
    user,
    tool,
    assistant,
};

pub const source: source_mod.Source = .{
    .name = "jsonl",
    .summary = "Tail a JSONL agent session log (one event per line) and record newly seen events.",
    .loadEvents = loadEvents,
};

fn loadEvents(
    arena: std.mem.Allocator,
    io: std.Io,
    options: source_mod.Options,
    checkpoint: checkpoint_mod.Checkpoint,
) !source_mod.LoadResult {
    const input_path = options.input_path orelse return error.ObserverInputRequired;
    const resolved = try resolveInputPath(arena, input_path);
    const instance_id = try hashPath(arena, resolved);

    if (checkpoint.instance_id) |existing| {
        if (!std.mem.eql(u8, existing, instance_id)) return error.ObserverCheckpointInstanceMismatch;
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, input_path, arena, max_input_bytes) catch |err| switch (err) {
        error.StreamTooLong => return error.ObserverInputTooLarge,
        else => return err,
    };

    // Watermark is the 1-based line number of the last processed event. Resume
    // strictly past it: positional line numbers are monotonic across appends to
    // the same file, so truncation-with-append ("added nothing new") yields zero
    // events rather than a not-found error. A rotated/replaced file at the same
    // path keeps the same instance_id (path hash); the ADR documents that limit.
    const start_line: usize = if (checkpoint.watermark) |wm|
        std.fmt.parseInt(usize, wm, 10) catch return error.ObserverWatermarkNotFound
    else
        0;

    var events: std.ArrayList(source_mod.Event) = .empty;
    var line_no: usize = 0;
    var iter = std.mem.splitScalar(u8, raw, '\n');
    while (iter.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (line_no <= start_line) continue;

        const ev = std.json.parseFromSliceLeaky(LineEvent, arena, trimmed, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.InvalidObserverEvent;

        if (ev.session_id.len == 0 or ev.cwd.len == 0) return error.InvalidObserverEvent;

        const kind = kindForRole(ev.role) orelse return error.InvalidObserverEvent;
        const event_name = ev.event_name orelse defaultEventName(ev.role);
        const watermark = try std.fmt.allocPrint(arena, "{d}", .{line_no});

        try events.append(arena, .{
            .origin = "jsonl",
            .session_id = ev.session_id,
            .workspace_cwd = ev.cwd,
            .event_name = event_name,
            .kind = kind,
            .watermark = watermark,
            .records = try buildRecords(arena, ev),
        });
    }

    return .{
        .instance_id = instance_id,
        .events = try events.toOwnedSlice(arena),
    };
}

fn resolveInputPath(arena: std.mem.Allocator, input_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(input_path)) return try arena.dupe(u8, input_path);
    return std.fs.path.resolve(arena, &.{ ".", input_path });
}

/// instance_id = Blake3 hex of the resolved absolute path. Stable across runs
/// for the same file (NOT mtime): the runner errors ObserverCheckpointInstanceMismatch
/// if it changes between runs.
fn hashPath(arena: std.mem.Allocator, resolved_path: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(resolved_path, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try arena.dupe(u8, &hex);
}

fn kindForRole(role: Role) ?event_mod.EventKind {
    return switch (role) {
        .user => .user_prompt,
        .tool => .tool_use,
        .assistant => .assistant,
    };
}

fn defaultEventName(role: Role) []const u8 {
    return switch (role) {
        .user => "UserPromptSubmit",
        .tool => "PostToolUse",
        .assistant => "Stop",
    };
}

fn buildRecords(arena: std.mem.Allocator, ev: LineEvent) ![]const source_mod.Record {
    switch (ev.role) {
        .user => {
            const content = ev.content orelse return error.InvalidObserverEvent;
            const records = try arena.alloc(source_mod.Record, 1);
            records[0] = .{ .user_prompt = content };
            return records;
        },
        .assistant => {
            const content = ev.content orelse return error.InvalidObserverEvent;
            const records = try arena.alloc(source_mod.Record, 1);
            records[0] = .{ .assistant = content };
            return records;
        },
        .tool => {
            const records = try arena.alloc(source_mod.Record, 1);
            records[0] = .{ .tool_use = .{
                .tool_name = ev.tool_name orelse return error.InvalidObserverEvent,
                .args = ev.args orelse return error.InvalidObserverEvent,
                .result = ev.result orelse return error.InvalidObserverEvent,
            } };
            return records;
        },
    }
}

test "jsonl source emits events past checkpoint watermark" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "session.jsonl", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{"session_id":"sess-1","cwd":".","role":"user","content":"hello"}
        \\{"session_id":"sess-1","cwd":".","role":"tool","tool_name":"bash","args":"echo hi","result":"hi"}
        \\{"session_id":"sess-1","cwd":".","role":"assistant","content":"done"}
        \\
    );

    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_len = try tmp.parent_dir.realPath(std.testing.io, &parent_buf);
    const real_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/session.jsonl",
        .{ parent_buf[0..parent_len], tmp.sub_path },
    );
    defer std.testing.allocator.free(real_path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const expected_instance = try hashPath(std.testing.allocator, real_path);
    defer std.testing.allocator.free(expected_instance);

    // Resume past line 1: only the tool + assistant events should come back.
    var checkpoint: checkpoint_mod.Checkpoint = .{
        .instance_id = try std.testing.allocator.dupe(u8, expected_instance),
        .watermark = try std.testing.allocator.dupe(u8, "1"),
    };
    defer checkpoint.deinit(std.testing.allocator);

    const result = try loadEvents(
        arena_state.allocator(),
        std.testing.io,
        .{ .input_path = real_path },
        checkpoint,
    );
    try std.testing.expectEqual(@as(usize, 2), result.events.len);
    try std.testing.expectEqualStrings("2", result.events[0].watermark);
    try std.testing.expectEqualStrings("3", result.events[1].watermark);
    try std.testing.expectEqualStrings("bash", result.events[0].records[0].tool_use.tool_name);
    try std.testing.expectEqualStrings("done", result.events[1].records[0].assistant);
    try std.testing.expectEqualStrings(expected_instance, result.instance_id.?);
}

test "jsonl source emits all events with empty checkpoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "session.jsonl", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{"session_id":"sess-1","cwd":".","role":"user","content":"hi"}
        \\
    );

    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_len = try tmp.parent_dir.realPath(std.testing.io, &parent_buf);
    const real_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/session.jsonl",
        .{ parent_buf[0..parent_len], tmp.sub_path },
    );
    defer std.testing.allocator.free(real_path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const result = try loadEvents(
        arena_state.allocator(),
        std.testing.io,
        .{ .input_path = real_path },
        .{},
    );
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    try std.testing.expectEqualStrings("1", result.events[0].watermark);
    try std.testing.expectEqual(@as(usize, 64), result.instance_id.?.len);
}

test "jsonl source rejects instance mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, "session.jsonl", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{"session_id":"sess-1","cwd":".","role":"user","content":"hi"}
        \\
    );

    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent_len = try tmp.parent_dir.realPath(std.testing.io, &parent_buf);
    const real_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/session.jsonl",
        .{ parent_buf[0..parent_len], tmp.sub_path },
    );
    defer std.testing.allocator.free(real_path);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var checkpoint: checkpoint_mod.Checkpoint = .{
        .instance_id = try std.testing.allocator.dupe(u8, "deadbeef"),
        .watermark = try std.testing.allocator.dupe(u8, "0"),
    };
    defer checkpoint.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.ObserverCheckpointInstanceMismatch,
        loadEvents(arena_state.allocator(), std.testing.io, .{ .input_path = real_path }, checkpoint),
    );
}

test "jsonl source normalizes relative input paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const normalized = try resolveInputPath(arena_state.allocator(), "./session.jsonl");
    try std.testing.expectEqualStrings("session.jsonl", normalized);
}

const std = @import("std");
const hook = @import("../hook.zig");
const recorder_mod = @import("../recorder.zig");
const file_lock_mod = @import("../util/file_lock.zig");
const fs_mod = @import("../util/fs.zig");

const Recorder = recorder_mod.Recorder;

pub const EventKind = enum {
    user_prompt,
    tool_use,
    assistant,
};

pub const NormalizeInput = struct {
    origin: []const u8,
    expected_event_name: []const u8,
    kind: EventKind,
    source_event_id: ?[]const u8 = null,
    preferred_turn_id: ?[]const u8 = null,
};

pub const WorkspaceDir = struct {
    dir: std.Io.Dir,
    used_fallback: bool,
};

pub fn openWorkspaceDir(io: std.Io, workspace_cwd: []const u8) !WorkspaceDir {
    const payload_dir = std.Io.Dir.cwd().openDir(io, workspace_cwd, .{}) catch {
        return .{
            .dir = try std.Io.Dir.cwd().openDir(io, ".", .{}),
            .used_fallback = true,
        };
    };
    return .{
        .dir = payload_dir,
        .used_fallback = false,
    };
}

pub const NormalizedEvent = struct {
    origin: []const u8,
    session_id: []const u8,
    turn_id: []u8,
    workspace_cwd: []const u8,
    event_name: []const u8,
    source_event_id: ?[]const u8 = null,
    recovered_turn: bool = false,
    lock: file_lock_mod.LockFile,

    pub fn deinit(self: *NormalizedEvent, io: std.Io, gpa: std.mem.Allocator) void {
        self.lock.release(io);
        gpa.free(self.turn_id);
        self.* = undefined;
    }
};

const TurnState = struct {
    next_seq: u64 = 1,
    active_turn_id: ?[]u8 = null,
};

const TurnStateDisk = struct {
    next_seq: u64 = 1,
    active_turn_id: ?[]const u8 = null,
};

pub fn normalize(
    io: std.Io,
    gpa: std.mem.Allocator,
    rec: *const Recorder,
    root: std.json.ObjectMap,
    diagnostic: *hook.Diagnostic,
    input: NormalizeInput,
) !NormalizedEvent {
    const session_id = try hook.requireString(root, "session_id", diagnostic);
    const workspace_cwd = try hook.requireString(root, "cwd", diagnostic);
    const event_name = try hook.requireString(root, "hook_event_name", diagnostic);
    try hook.requireEvent(event_name, input.expected_event_name, diagnostic);

    try rec.store.root.createDirPath(io, "tmp/turns");

    const session_key = sessionKey(input.origin, session_id);
    var lock_path_buf: [96]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&lock_path_buf, "tmp/turns/{s}.lock", .{session_key}) catch unreachable;
    var lock = try file_lock_mod.LockFile.acquire(io, rec.store.root, lock_path, .{});
    errdefer lock.release(io);

    var state_path_buf: [96]u8 = undefined;
    const state_path = std.fmt.bufPrint(&state_path_buf, "tmp/turns/{s}.json", .{session_key}) catch unreachable;
    var state = try readState(io, rec.store.root, gpa, state_path);
    defer freeState(&state, gpa);

    const resolved = try resolveTurnId(gpa, &state, input.kind, input.preferred_turn_id);
    errdefer gpa.free(resolved.turn_id);

    try writeState(io, rec.store.root, gpa, state_path, state);

    return .{
        .origin = input.origin,
        .session_id = session_id,
        .turn_id = resolved.turn_id,
        .workspace_cwd = workspace_cwd,
        .event_name = event_name,
        .source_event_id = input.source_event_id,
        .recovered_turn = resolved.recovered,
        .lock = lock,
    };
}

const TurnResolution = struct {
    turn_id: []u8,
    recovered: bool,
};

fn resolveTurnId(
    gpa: std.mem.Allocator,
    state: *TurnState,
    kind: EventKind,
    preferred_turn_id: ?[]const u8,
) !TurnResolution {
    if (preferred_turn_id) |provided| {
        if (provided.len > 0) {
            const turn_id = try gpa.dupe(u8, provided);
            switch (kind) {
                .assistant => try setActiveTurnId(gpa, state, null),
                else => try setActiveTurnId(gpa, state, provided),
            }
            return .{ .turn_id = turn_id, .recovered = false };
        }
    }

    switch (kind) {
        .user_prompt => {
            const turn_id = try std.fmt.allocPrint(gpa, "agturn:{d}", .{state.next_seq});
            state.next_seq += 1;
            try setActiveTurnId(gpa, state, turn_id);
            return .{ .turn_id = turn_id, .recovered = false };
        },
        .tool_use => {
            if (state.active_turn_id) |active| {
                return .{ .turn_id = try gpa.dupe(u8, active), .recovered = false };
            }
            const turn_id = try std.fmt.allocPrint(gpa, "agrecovery:{d}", .{state.next_seq});
            state.next_seq += 1;
            try setActiveTurnId(gpa, state, turn_id);
            return .{ .turn_id = turn_id, .recovered = true };
        },
        .assistant => {
            if (state.active_turn_id) |active| {
                const turn_id = try gpa.dupe(u8, active);
                try setActiveTurnId(gpa, state, null);
                return .{ .turn_id = turn_id, .recovered = false };
            }
            const turn_id = try std.fmt.allocPrint(gpa, "agrecovery:{d}", .{state.next_seq});
            state.next_seq += 1;
            return .{ .turn_id = turn_id, .recovered = true };
        },
    }
}

fn readState(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    state_path: []const u8,
) !TurnState {
    const raw = root.readFileAlloc(io, state_path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer gpa.free(raw);

    var parsed = std.json.parseFromSlice(TurnStateDisk, gpa, raw, .{
        .allocate = .alloc_always,
    }) catch return .{};
    defer parsed.deinit();

    var state: TurnState = .{
        .next_seq = if (parsed.value.next_seq == 0) 1 else parsed.value.next_seq,
    };
    if (parsed.value.active_turn_id) |active| {
        if (active.len > 0) {
            state.active_turn_id = try gpa.dupe(u8, active);
        }
    }
    return state;
}

fn writeState(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    state_path: []const u8,
    state: TurnState,
) !void {
    try root.createDirPath(io, "tmp/turns");

    var writer: std.Io.Writer.Allocating = .init(gpa);
    defer writer.deinit();
    try std.json.Stringify.value(TurnStateDisk{
        .next_seq = state.next_seq,
        .active_turn_id = if (state.active_turn_id) |active| active else null,
    }, .{}, &writer.writer);

    var af = try root.createFileAtomic(io, state_path, .{ .replace = true, .make_path = false });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, writer.writer.buffered());
    try fs_mod.atomicReplace(io, &af);
}

fn freeState(state: *TurnState, gpa: std.mem.Allocator) void {
    if (state.active_turn_id) |active| gpa.free(active);
    state.* = .{};
}

fn setActiveTurnId(gpa: std.mem.Allocator, state: *TurnState, turn_id: ?[]const u8) !void {
    if (state.active_turn_id) |active| gpa.free(active);
    if (turn_id) |value| {
        state.active_turn_id = try gpa.dupe(u8, value);
    } else {
        state.active_turn_id = null;
    }
}

fn sessionKey(origin: []const u8, session_id: []const u8) [64]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    var len_buf: [8]u8 = undefined;

    std.mem.writeInt(u64, &len_buf, origin.len, .little);
    hasher.update(&len_buf);
    hasher.update(origin);

    std.mem.writeInt(u64, &len_buf, session_id.len, .little);
    hasher.update(&len_buf);
    hasher.update(session_id);

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

test "resolveTurnId uses preferred turn id" {
    const gpa = std.testing.allocator;
    var state: TurnState = .{};
    defer freeState(&state, gpa);

    const resolved = try resolveTurnId(gpa, &state, .user_prompt, "turn-explicit");
    defer gpa.free(resolved.turn_id);
    try std.testing.expect(!resolved.recovered);
    try std.testing.expectEqualStrings("turn-explicit", resolved.turn_id);
    try std.testing.expect(state.active_turn_id != null);
    try std.testing.expectEqualStrings("turn-explicit", state.active_turn_id.?);
}

test "resolveTurnId generates monotonic fallback ids" {
    const gpa = std.testing.allocator;
    var state: TurnState = .{};
    defer freeState(&state, gpa);

    const first = try resolveTurnId(gpa, &state, .user_prompt, null);
    defer gpa.free(first.turn_id);
    const second = try resolveTurnId(gpa, &state, .assistant, null);
    defer gpa.free(second.turn_id);
    const third = try resolveTurnId(gpa, &state, .user_prompt, null);
    defer gpa.free(third.turn_id);

    try std.testing.expectEqualStrings("agturn:1", first.turn_id);
    try std.testing.expectEqualStrings("agturn:1", second.turn_id);
    try std.testing.expectEqualStrings("agturn:2", third.turn_id);
}

test "resolveTurnId creates recovery id when active turn is missing" {
    const gpa = std.testing.allocator;
    var state: TurnState = .{};
    defer freeState(&state, gpa);

    const tool = try resolveTurnId(gpa, &state, .tool_use, null);
    defer gpa.free(tool.turn_id);
    try std.testing.expect(tool.recovered);
    try std.testing.expectEqualStrings("agrecovery:1", tool.turn_id);

    const assistant = try resolveTurnId(gpa, &state, .assistant, null);
    defer gpa.free(assistant.turn_id);
    try std.testing.expect(!assistant.recovered);
    try std.testing.expectEqualStrings("agrecovery:1", assistant.turn_id);
    try std.testing.expect(state.active_turn_id == null);
}

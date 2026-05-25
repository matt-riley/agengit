const std = @import("std");
const exe_path_mod = @import("../util/exe_path.zig");
const home_mod = @import("../util/home.zig");
const atomic_json_mod = @import("../util/atomic_json.zig");

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    _ = iter;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const home = try home_mod.getAlloc(gpa, environ);
    defer gpa.free(home);
    const exe = try exe_path_mod.getAlloc(io, gpa);
    defer gpa.free(exe);
    const crash_after_tmp_write = shouldCrashAfterTmpWrite(environ);

    try uninstallAgent(io, gpa, home, exe, ".claude/settings.json", crash_after_tmp_write, &stdout, removeClaude);
    try uninstallAgent(io, gpa, home, exe, ".codex/hooks.json", crash_after_tmp_write, &stdout, removeSimpleHooks);
    try uninstallAgent(io, gpa, home, exe, ".gemini/settings.json", crash_after_tmp_write, &stdout, removeSimpleHooks);

    try stdout.flush();
}

const RemoveFn = *const fn (aa: std.mem.Allocator, root: *std.json.ObjectMap, binary: []const u8) std.mem.Allocator.Error!bool;

fn uninstallAgent(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    rel_config: []const u8,
    crash_after_tmp_write: bool,
    stdout: *std.Io.File.Writer,
    removeFn: RemoveFn,
) !void {
    const config_path = try std.mem.concat(gpa, u8, &.{ home, "/", rel_config });
    defer gpa.free(config_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const loaded = atomic_json_mod.loadObject(io, aa, config_path) catch |err| {
        reportReadError(io, stdout, config_path, err);
        return err;
    };
    var root = switch (loaded) {
        .missing => return,
        .malformed => |diag| {
            reportMalformedWarning(io, stdout, diag);
            return;
        },
        .not_object => {
            reportRootNotObjectWarning(io, stdout, config_path);
            return;
        },
        .object => |value| value.object,
    };

    // Identify the stored binary that was installed.
    const stored_binary: []const u8 = blk: {
        const agit = root.get("_agit") orelse return; // not agit-managed
        if (agit != .object) return;
        const bin = agit.object.get("binary") orelse return;
        if (bin != .string) return;
        break :blk bin.string;
    };
    _ = exe; // use stored binary for matching; exe may differ if binary moved

    const changed = try removeFn(aa, &root, stored_binary);
    _ = root.swapRemove("_agit");

    if (!changed) {
        try stdout.interface.print("agit uninstall: no agit hooks found in {s}\n", .{config_path});
        return;
    }

    atomic_json_mod.writeAtomic(io, aa, config_path, std.json.Value{ .object = root }, .{
        .crash_after_tmp_write = crash_after_tmp_write,
    }) catch |err| {
        reportWriteError(io, stdout, config_path, err);
        return err;
    };
    try stdout.interface.print("agit uninstall: removed agit hooks from {s}\n", .{config_path});
}

fn shouldCrashAfterTmpWrite(environ: std.process.Environ) bool {
    const raw = environ.getPosix("AGIT_CRASH_AFTER") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "tmp_write");
}

fn reportMalformedWarning(io: std.Io, stdout: *std.Io.File.Writer, diag: atomic_json_mod.MalformedJson) void {
    stdout.interface.print(
        "agit uninstall: warning: skipped malformed JSON config {s} at offset={d} line={d} column={d}\n",
        .{ diag.path, diag.offset, diag.line, diag.column },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportRootNotObjectWarning(io: std.Io, stdout: *std.Io.File.Writer, path: []const u8) void {
    stdout.interface.print(
        "agit uninstall: warning: skipped non-object JSON config {s}\n",
        .{path},
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportReadError(io: std.Io, stdout: *std.Io.File.Writer, path: []const u8, err: anyerror) void {
    stdout.interface.print(
        "agit uninstall: failed to read config {s}: {s}\n",
        .{ path, @errorName(err) },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportWriteError(io: std.Io, stdout: *std.Io.File.Writer, path: []const u8, err: anyerror) void {
    stdout.interface.print(
        "agit uninstall: failed to write config {s}: {s}\n",
        .{ path, @errorName(err) },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

/// Remove Claude-format hook entries: each event value is an array of
/// `{hooks: [{type, command, args}]}` groups; remove groups where
/// `hooks[0].command == binary`.
fn removeClaude(aa: std.mem.Allocator, root: *std.json.ObjectMap, binary: []const u8) std.mem.Allocator.Error!bool {
    var changed = false;
    const hooks_val = root.get("hooks") orelse return false;
    if (hooks_val != .object) return false;

    var new_hooks = std.json.ObjectMap.empty;
    var ev_it = hooks_val.object.iterator();
    while (ev_it.next()) |ev_entry| {
        const event_val = ev_entry.value_ptr.*;
        if (event_val != .array) {
            try new_hooks.put(aa, ev_entry.key_ptr.*, event_val);
            continue;
        }
        var filtered = std.json.Array.init(aa);
        for (event_val.array.items) |group| {
            if (isClaudeAgitGroup(group, binary)) {
                changed = true;
                continue;
            }
            try filtered.append(group);
        }
        if (filtered.items.len > 0) {
            try new_hooks.put(aa, ev_entry.key_ptr.*, std.json.Value{ .array = filtered });
        } else {
            changed = true; // event key removed
        }
    }

    if (changed) {
        try root.put(aa, "hooks", std.json.Value{ .object = new_hooks });
    }
    return changed;
}

fn isClaudeAgitGroup(group: std.json.Value, binary: []const u8) bool {
    if (group != .object) return false;
    const inner = group.object.get("hooks") orelse return false;
    if (inner != .array or inner.array.items.len == 0) return false;
    const first = inner.array.items[0];
    if (first != .object) return false;
    const cmd = first.object.get("command") orelse return false;
    if (cmd != .string) return false;
    return std.mem.eql(u8, cmd.string, binary);
}

/// Remove Codex/Gemini-format hook entries: each event value is an object
/// `{command: "<binary> <subcmd>"}`.  Remove event keys where command
/// starts with `binary + " "`.
fn removeSimpleHooks(aa: std.mem.Allocator, root: *std.json.ObjectMap, binary: []const u8) std.mem.Allocator.Error!bool {
    var changed = false;
    const hooks_val = root.get("hooks") orelse return false;
    if (hooks_val != .object) return false;

    var to_remove: [16][]const u8 = undefined;
    var n_to_remove: usize = 0;
    var it = hooks_val.object.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        if (v != .object) continue;
        const cmd = v.object.get("command") orelse continue;
        if (cmd != .string) continue;
        const is_agit_cmd = std.mem.eql(u8, cmd.string, binary) or
            (std.mem.startsWith(u8, cmd.string, binary) and
                cmd.string.len > binary.len and cmd.string[binary.len] == ' ');
        if (is_agit_cmd and n_to_remove < to_remove.len) {
            to_remove[n_to_remove] = entry.key_ptr.*;
            n_to_remove += 1;
            changed = true;
        }
    }

    var hooks_obj = hooks_val.object;
    for (to_remove[0..n_to_remove]) |key| {
        _ = hooks_obj.swapRemove(key);
    }
    if (changed) {
        try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });
    }
    return changed;
}

test "removeClaude removes agit-managed hooks and returns changed" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // Build a root object as if agit init had written it.
    var stop_entry_obj = std.json.ObjectMap.empty;
    try stop_entry_obj.put(aa, "type", std.json.Value{ .string = "command" });
    try stop_entry_obj.put(aa, "command", std.json.Value{ .string = "/bin/agit" });
    try stop_entry_obj.put(aa, "args", std.json.Value{ .array = std.json.Array.init(aa) });

    var inner_hooks = std.json.Array.init(aa);
    try inner_hooks.append(std.json.Value{ .object = stop_entry_obj });
    var group_obj = std.json.ObjectMap.empty;
    try group_obj.put(aa, "hooks", std.json.Value{ .array = inner_hooks });

    var stop_arr = std.json.Array.init(aa);
    try stop_arr.append(std.json.Value{ .object = group_obj });

    var hooks_obj = std.json.ObjectMap.empty;
    try hooks_obj.put(aa, "Stop", std.json.Value{ .array = stop_arr });

    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });

    const changed = try removeClaude(aa, &root, "/bin/agit");
    try std.testing.expect(changed);
    // The Stop event should be gone.
    const remaining = root.get("hooks").?.object;
    try std.testing.expect(remaining.get("Stop") == null);
}

test "removeClaude on empty root returns not changed" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var root = std.json.ObjectMap.empty;
    const changed = try removeClaude(aa, &root, "/bin/agit");
    try std.testing.expect(!changed);
}

test "removeClaude preserves user hooks on other events" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // Agit hook on Stop.
    var agit_entry_obj = std.json.ObjectMap.empty;
    try agit_entry_obj.put(aa, "type", std.json.Value{ .string = "command" });
    try agit_entry_obj.put(aa, "command", std.json.Value{ .string = "/bin/agit" });
    try agit_entry_obj.put(aa, "args", std.json.Value{ .array = std.json.Array.init(aa) });
    var agit_inner = std.json.Array.init(aa);
    try agit_inner.append(std.json.Value{ .object = agit_entry_obj });
    var agit_group = std.json.ObjectMap.empty;
    try agit_group.put(aa, "hooks", std.json.Value{ .array = agit_inner });
    var stop_arr = std.json.Array.init(aa);
    try stop_arr.append(std.json.Value{ .object = agit_group });

    // User hook on PreTool.
    var user_entry_obj = std.json.ObjectMap.empty;
    try user_entry_obj.put(aa, "type", std.json.Value{ .string = "command" });
    try user_entry_obj.put(aa, "command", std.json.Value{ .string = "/bin/mytool" });
    try user_entry_obj.put(aa, "args", std.json.Value{ .array = std.json.Array.init(aa) });
    var user_inner = std.json.Array.init(aa);
    try user_inner.append(std.json.Value{ .object = user_entry_obj });
    var user_group = std.json.ObjectMap.empty;
    try user_group.put(aa, "hooks", std.json.Value{ .array = user_inner });
    var pre_tool_arr = std.json.Array.init(aa);
    try pre_tool_arr.append(std.json.Value{ .object = user_group });

    var hooks_obj = std.json.ObjectMap.empty;
    try hooks_obj.put(aa, "Stop", std.json.Value{ .array = stop_arr });
    try hooks_obj.put(aa, "PreTool", std.json.Value{ .array = pre_tool_arr });
    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });

    const changed = try removeClaude(aa, &root, "/bin/agit");
    try std.testing.expect(changed);
    const remaining = root.get("hooks").?.object;
    // agit's Stop entry removed; user's PreTool entry preserved.
    try std.testing.expect(remaining.get("Stop") == null);
    try std.testing.expect(remaining.get("PreTool") != null);
}

test "removeSimpleHooks removes agit-managed Codex/Gemini hooks" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var stop_obj = std.json.ObjectMap.empty;
    try stop_obj.put(aa, "command", std.json.Value{ .string = "/bin/agit codex-hook" });
    var hooks_obj = std.json.ObjectMap.empty;
    try hooks_obj.put(aa, "Stop", std.json.Value{ .object = stop_obj });
    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });

    const changed = try removeSimpleHooks(aa, &root, "/bin/agit");
    try std.testing.expect(changed);
    const remaining = root.get("hooks").?.object;
    try std.testing.expect(remaining.get("Stop") == null);
}

test "removeSimpleHooks does not remove commands from a different binary" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var stop_obj = std.json.ObjectMap.empty;
    try stop_obj.put(aa, "command", std.json.Value{ .string = "/bin/other-tool codex-hook" });
    var hooks_obj = std.json.ObjectMap.empty;
    try hooks_obj.put(aa, "Stop", std.json.Value{ .object = stop_obj });
    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });

    const changed = try removeSimpleHooks(aa, &root, "/bin/agit");
    try std.testing.expect(!changed);
    try std.testing.expect(root.get("hooks").?.object.get("Stop") != null);
}

test "removeSimpleHooks on empty root returns not changed" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var root = std.json.ObjectMap.empty;
    const changed = try removeSimpleHooks(aa, &root, "/bin/agit");
    try std.testing.expect(!changed);
}

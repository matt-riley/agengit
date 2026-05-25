const std = @import("std");
const exe_path_mod = @import("../util/exe_path.zig");

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    _ = iter;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const home = environ.getPosix("HOME") orelse return error.MissingHOME;
    const exe = try exe_path_mod.getAlloc(io, gpa);
    defer gpa.free(exe);

    const has_claude = detectBinary(io, gpa, "claude");
    const has_codex = detectBinary(io, gpa, "codex");
    const has_gemini = detectBinary(io, gpa, "gemini");

    if (!has_claude and !has_codex and !has_gemini) {
        try stdout.interface.writeAll("agit init: no supported agent (claude, codex, gemini) found in PATH.\n");
        try stdout.flush();
        return;
    }

    if (has_claude) {
        try installClaude(io, gpa, home, exe, &stdout);
    }
    if (has_codex) {
        try installCodex(io, gpa, home, exe, &stdout);
    }
    if (has_gemini) {
        try installGemini(io, gpa, home, exe, &stdout);
    }

    try stdout.flush();
}

fn detectBinary(io: std.Io, gpa: std.mem.Allocator, name: []const u8) bool {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "which", name } }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn homePath(gpa: std.mem.Allocator, home: []const u8, subpath: []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, &.{ home, "/", subpath });
}

/// Back up `path` to `path.agit.bak` if the file exists.
fn backupIfExists(io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    const content = (readFileAllocOrNull(io, gpa, path) catch return) orelse return;
    defer gpa.free(content);

    var bak_buf: [std.fs.max_path_bytes + 9]u8 = undefined;
    const bak = std.fmt.bufPrint(&bak_buf, "{s}.agit.bak", .{path}) catch return;
    writeFileAtomic(io, bak, content) catch {};
}

fn installClaude(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = try homePath(gpa, home, ".claude/settings.json");
    defer gpa.free(config_path);
    const dir_path = try homePath(gpa, home, ".claude");
    defer gpa.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    backupIfExists(io, gpa, config_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = try loadOrEmptyObject(io, aa, config_path);
    try setClaudeHooks(aa, &root.object, exe);

    const json_str = try std.json.Stringify.valueAlloc(aa, root, .{ .whitespace = .indent_2 });
    try writeFileAtomic(io, config_path, json_str);

    try stdout.interface.print("agit init: wrote Claude Code hooks to {s}\n", .{config_path});
}

fn installCodex(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = try homePath(gpa, home, ".codex/hooks.json");
    defer gpa.free(config_path);
    const dir_path = try homePath(gpa, home, ".codex");
    defer gpa.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    backupIfExists(io, gpa, config_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = try loadOrEmptyObject(io, aa, config_path);
    try setCodexHooks(aa, &root.object, exe);

    const json_str = try std.json.Stringify.valueAlloc(aa, root, .{ .whitespace = .indent_2 });
    try writeFileAtomic(io, config_path, json_str);

    try stdout.interface.print("agit init: wrote Codex CLI hooks to {s}\n", .{config_path});
}

fn installGemini(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = try homePath(gpa, home, ".gemini/settings.json");
    defer gpa.free(config_path);
    const dir_path = try homePath(gpa, home, ".gemini");
    defer gpa.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    backupIfExists(io, gpa, config_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = try loadOrEmptyObject(io, aa, config_path);
    try setGeminiHooks(aa, &root.object, exe);

    const json_str = try std.json.Stringify.valueAlloc(aa, root, .{ .whitespace = .indent_2 });
    try writeFileAtomic(io, config_path, json_str);

    try stdout.interface.print("agit init: wrote Gemini CLI hooks to {s}\n", .{config_path});
}

/// Parse `path` as a JSON object using `aa`.  Returns an empty object on
/// missing file, parse error, or non-object root.  All allocations go into
/// `aa` so no separate cleanup is required.
fn loadOrEmptyObject(io: std.Io, aa: std.mem.Allocator, path: []const u8) !std.json.Value {
    const text = (readFileAllocOrNull(io, aa, path) catch null) orelse
        return std.json.Value{ .object = .empty };
    const v = std.json.parseFromSliceLeaky(std.json.Value, aa, text, .{
        .allocate = .alloc_always,
    }) catch return std.json.Value{ .object = .empty };
    if (v != .object) return std.json.Value{ .object = .empty };
    return v;
}

/// Merge agit-managed entries into Claude Code settings.json hooks object.
/// All allocations use `aa` so the caller's arena owns everything.
fn setClaudeHooks(aa: std.mem.Allocator, root: *std.json.ObjectMap, exe: []const u8) !void {
    var hooks_obj = std.json.ObjectMap.empty;
    try hooks_obj.put(aa, "UserPromptSubmit", try makeClaudeList(aa, exe, &.{ "claude-hook", "user" }));
    try hooks_obj.put(aa, "PostToolBatch", try makeClaudeList(aa, exe, &.{"claude-tool-batch-hook"}));
    try hooks_obj.put(aa, "Stop", try makeClaudeList(aa, exe, &.{ "claude-hook", "assistant" }));

    // Preserve existing non-agit hooks for event names we don't manage.
    if (root.get("hooks")) |existing| {
        if (existing == .object) {
            var it = existing.object.iterator();
            while (it.next()) |entry| {
                if (hooks_obj.get(entry.key_ptr.*) != null) continue;
                try hooks_obj.put(aa, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });

    var agit_meta = std.json.ObjectMap.empty;
    try agit_meta.put(aa, "binary", std.json.Value{ .string = exe });
    try root.put(aa, "_agit", std.json.Value{ .object = agit_meta });
}

/// Build a Claude-format hook list: [{hooks: [{type: "command", command: exe, args: [...]}]}]
fn makeClaudeList(aa: std.mem.Allocator, exe: []const u8, args: []const []const u8) !std.json.Value {
    var entry_obj = std.json.ObjectMap.empty;
    try entry_obj.put(aa, "type", std.json.Value{ .string = "command" });
    try entry_obj.put(aa, "command", std.json.Value{ .string = exe });

    var args_arr = std.json.Array.init(aa);
    for (args) |arg| {
        try args_arr.append(std.json.Value{ .string = arg });
    }
    try entry_obj.put(aa, "args", std.json.Value{ .array = args_arr });

    var inner_hooks = std.json.Array.init(aa);
    try inner_hooks.append(std.json.Value{ .object = entry_obj });

    var outer_obj = std.json.ObjectMap.empty;
    try outer_obj.put(aa, "hooks", std.json.Value{ .array = inner_hooks });

    var outer_arr = std.json.Array.init(aa);
    try outer_arr.append(std.json.Value{ .object = outer_obj });

    return std.json.Value{ .array = outer_arr };
}

/// Merge agit-managed entries into Codex hooks.json.
fn setCodexHooks(aa: std.mem.Allocator, root: *std.json.ObjectMap, exe: []const u8) !void {
    var hooks_obj = std.json.ObjectMap.empty;
    try hooks_obj.put(aa, "UserPromptSubmit", try makeCodexHook(aa, exe, "codex-hook"));
    try hooks_obj.put(aa, "PostToolUse", try makeCodexHook(aa, exe, "codex-hook"));
    try hooks_obj.put(aa, "Stop", try makeCodexHook(aa, exe, "codex-hook"));

    if (root.get("hooks")) |existing| {
        if (existing == .object) {
            var it = existing.object.iterator();
            while (it.next()) |entry| {
                if (hooks_obj.get(entry.key_ptr.*) != null) continue;
                try hooks_obj.put(aa, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });

    var agit_meta = std.json.ObjectMap.empty;
    try agit_meta.put(aa, "binary", std.json.Value{ .string = exe });
    try root.put(aa, "_agit", std.json.Value{ .object = agit_meta });
}

fn makeCodexHook(aa: std.mem.Allocator, exe: []const u8, subcmd: []const u8) !std.json.Value {
    const cmd = try std.mem.concat(aa, u8, &.{ exe, " ", subcmd });
    var obj = std.json.ObjectMap.empty;
    try obj.put(aa, "command", std.json.Value{ .string = cmd });
    return std.json.Value{ .object = obj };
}

/// Merge agit-managed entries into Gemini settings.json.
fn setGeminiHooks(aa: std.mem.Allocator, root: *std.json.ObjectMap, exe: []const u8) !void {
    var hooks_obj = std.json.ObjectMap.empty;
    try hooks_obj.put(aa, "AfterTool", try makeGeminiHook(aa, exe, "gemini-hook"));
    try hooks_obj.put(aa, "AfterAgent", try makeGeminiHook(aa, exe, "gemini-hook"));

    if (root.get("hooks")) |existing| {
        if (existing == .object) {
            var it = existing.object.iterator();
            while (it.next()) |entry| {
                if (hooks_obj.get(entry.key_ptr.*) != null) continue;
                try hooks_obj.put(aa, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    try root.put(aa, "hooks", std.json.Value{ .object = hooks_obj });

    var agit_meta = std.json.ObjectMap.empty;
    try agit_meta.put(aa, "binary", std.json.Value{ .string = exe });
    try root.put(aa, "_agit", std.json.Value{ .object = agit_meta });
}

fn makeGeminiHook(aa: std.mem.Allocator, exe: []const u8, subcmd: []const u8) !std.json.Value {
    const cmd = try std.mem.concat(aa, u8, &.{ exe, " ", subcmd });
    var obj = std.json.ObjectMap.empty;
    try obj.put(aa, "command", std.json.Value{ .string = cmd });
    return std.json.Value{ .object = obj };
}

/// Read a file into a slice allocated with `allocator`.  Returns null if the
/// file does not exist.  Caller owns the returned slice.
fn readFileAllocOrNull(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) return null;

    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

/// Write `content` to `path` atomically (temp-file + rename).
fn writeFileAtomic(io: std.Io, path: []const u8, content: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = false });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, content);
    try af.replace(io);
}

test "setClaudeHooks installs all managed events on empty root" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = std.json.ObjectMap.empty;
    try setClaudeHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks") orelse return error.MissingHooks;
    try std.testing.expect(hooks == .object);
    try std.testing.expect(hooks.object.get("UserPromptSubmit") != null);
    try std.testing.expect(hooks.object.get("PostToolBatch") != null);
    try std.testing.expect(hooks.object.get("Stop") != null);

    const meta = root.get("_agit") orelse return error.MissingMeta;
    try std.testing.expectEqualStrings("/bin/agit", meta.object.get("binary").?.string);
}

test "setClaudeHooks is idempotent" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = std.json.ObjectMap.empty;
    try setClaudeHooks(aa, &root, "/bin/agit");
    try setClaudeHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks").?.object;
    try std.testing.expect(hooks.get("UserPromptSubmit") != null);
    try std.testing.expect(hooks.get("PostToolBatch") != null);
    try std.testing.expect(hooks.get("Stop") != null);
    // No duplicate event keys — object map dedups by key.
    try std.testing.expectEqual(@as(usize, 3), hooks.count());
}

test "setClaudeHooks preserves user hooks on other event names" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // Pre-populate hooks with a user-owned PreTool entry.
    var user_arr = std.json.Array.init(aa);
    try user_arr.append(std.json.Value{ .string = "user-entry" });
    var existing_hooks = std.json.ObjectMap.empty;
    try existing_hooks.put(aa, "PreTool", std.json.Value{ .array = user_arr });

    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = existing_hooks });

    try setClaudeHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks").?.object;
    // Managed events installed.
    try std.testing.expect(hooks.get("UserPromptSubmit") != null);
    // User's PreTool entry preserved.
    try std.testing.expect(hooks.get("PreTool") != null);
}

test "setCodexHooks installs all managed events on empty root" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = std.json.ObjectMap.empty;
    try setCodexHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks").?.object;
    try std.testing.expect(hooks.get("UserPromptSubmit") != null);
    try std.testing.expect(hooks.get("PostToolUse") != null);
    try std.testing.expect(hooks.get("Stop") != null);
    try std.testing.expectEqualStrings("/bin/agit", root.get("_agit").?.object.get("binary").?.string);
}

test "setGeminiHooks installs all managed events on empty root" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = std.json.ObjectMap.empty;
    try setGeminiHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks").?.object;
    try std.testing.expect(hooks.get("AfterTool") != null);
    try std.testing.expect(hooks.get("AfterAgent") != null);
    try std.testing.expectEqualStrings("/bin/agit", root.get("_agit").?.object.get("binary").?.string);
}

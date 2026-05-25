const std = @import("std");
const exe_path_mod = @import("../util/exe_path.zig");
const fs_mod = @import("../util/fs.zig");
const home_mod = @import("../util/home.zig");

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => {
            try stdout.flush();
            return;
        },
        else => return err,
    };

    const home = try home_mod.getAlloc(gpa, environ);
    defer gpa.free(home);
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
        try installClaude(io, gpa, home, exe, options, &stdout);
    }
    if (has_codex) {
        try installCodex(io, gpa, home, exe, options, &stdout);
    }
    if (has_gemini) {
        try installGemini(io, gpa, home, exe, options, &stdout);
    }

    try stdout.flush();
}

const InitOptions = struct {
    force: bool = false,
};

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !InitOptions {
    var options: InitOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stdout);
            return error.HelpShown;
        } else {
            try stdout.interface.print("agit init: unknown option '{s}'\n\n", .{arg});
            try printUsage(stdout);
            try stdout.flush();
            return error.InvalidArgument;
        }
    }
    return options;
}

fn printUsage(stdout: *std.Io.File.Writer) !void {
    try stdout.interface.writeAll(
        \\Usage: agit init [--force]
        \\
        \\Set up agit hooks for installed agent CLIs.
        \\
        \\Options:
        \\  --force      Back up and replace malformed/non-object existing JSON config.
        \\  -h, --help   Display this help and exit.
        \\
    );
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
fn backupIfExists(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !bool {
    const content = (try readFileAllocOrNull(io, gpa, path)) orelse return false;
    defer gpa.free(content);

    const bak = try std.fmt.allocPrint(gpa, "{s}.agit.bak", .{path});
    defer gpa.free(bak);
    try writeFileAtomic(io, bak, content);
    return true;
}

fn installClaude(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    options: InitOptions,
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
    try backupConfigOrReport(io, gpa, config_path, stdout);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = loadOrEmptyObject(io, aa, config_path, options) catch |err| {
        reportConfigLoadError(io, stdout, config_path, err);
        return err;
    };
    try setClaudeHooks(aa, &root.object, exe);

    const json_str = try std.json.Stringify.valueAlloc(aa, root, .{ .whitespace = .indent_2 });
    writeFileAtomic(io, config_path, json_str) catch |err| {
        reportWriteError(io, stdout, config_path, err);
        return err;
    };

    try stdout.interface.print("agit init: wrote Claude Code hooks to {s}\n", .{config_path});
}

fn installCodex(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    options: InitOptions,
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
    try backupConfigOrReport(io, gpa, config_path, stdout);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = loadOrEmptyObject(io, aa, config_path, options) catch |err| {
        reportConfigLoadError(io, stdout, config_path, err);
        return err;
    };
    try setCodexHooks(aa, &root.object, exe);

    const json_str = try std.json.Stringify.valueAlloc(aa, root, .{ .whitespace = .indent_2 });
    writeFileAtomic(io, config_path, json_str) catch |err| {
        reportWriteError(io, stdout, config_path, err);
        return err;
    };

    try stdout.interface.print("agit init: wrote Codex CLI hooks to {s}\n", .{config_path});
}

fn installGemini(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    options: InitOptions,
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
    try backupConfigOrReport(io, gpa, config_path, stdout);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = loadOrEmptyObject(io, aa, config_path, options) catch |err| {
        reportConfigLoadError(io, stdout, config_path, err);
        return err;
    };
    try setGeminiHooks(aa, &root.object, exe);

    const json_str = try std.json.Stringify.valueAlloc(aa, root, .{ .whitespace = .indent_2 });
    writeFileAtomic(io, config_path, json_str) catch |err| {
        reportWriteError(io, stdout, config_path, err);
        return err;
    };

    try stdout.interface.print("agit init: wrote Gemini CLI hooks to {s}\n", .{config_path});
}

fn backupConfigOrReport(io: std.Io, gpa: std.mem.Allocator, path: []const u8, stdout: *std.Io.File.Writer) !void {
    _ = backupIfExists(io, gpa, path) catch |err| {
        try stdout.interface.print(
            "agit init: failed to back up existing config {s}: {s}\n",
            .{ path, @errorName(err) },
        );
        try stdout.flush();
        return err;
    };
}

fn reportConfigLoadError(io: std.Io, stdout: *std.Io.File.Writer, path: []const u8, err: anyerror) void {
    stdout.interface.print(
        "agit init: refusing to overwrite {s}: {s}. Fix the JSON or rerun 'agit init --force' to back up and replace it.\n",
        .{ path, @errorName(err) },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportWriteError(io: std.Io, stdout: *std.Io.File.Writer, path: []const u8, err: anyerror) void {
    stdout.interface.print(
        "agit init: failed to write config {s}: {s}\n",
        .{ path, @errorName(err) },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

/// Parse `path` as a JSON object using `aa`. Returns an empty object only when
/// the file is missing, or when `--force` explicitly allows replacing malformed
/// or non-object JSON. All allocations go into `aa`.
fn loadOrEmptyObject(io: std.Io, aa: std.mem.Allocator, path: []const u8, options: InitOptions) !std.json.Value {
    const text = (try readExistingFileAllocOrNull(io, aa, path)) orelse
        return std.json.Value{ .object = .empty };
    const v = std.json.parseFromSliceLeaky(std.json.Value, aa, text, .{
        .allocate = .alloc_always,
    }) catch {
        if (options.force) return std.json.Value{ .object = .empty };
        return error.InvalidConfigJson;
    };
    if (v != .object) {
        if (options.force) return std.json.Value{ .object = .empty };
        return error.ConfigRootNotObject;
    }
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

/// Read an existing config file into an owned slice. Unlike backup reads, an
/// empty existing config is still returned so JSON validation can reject it.
fn readExistingFileAllocOrNull(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    if (buf.len > 0) {
        _ = try file.readPositionalAll(io, buf, 0);
    }
    return buf;
}

/// Write `content` to `path` atomically (temp-file + rename).
fn writeFileAtomic(io: std.Io, path: []const u8, content: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = false });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, content);
    try fs_mod.atomicReplace(io, &af);
}

fn testPath(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &real_buf);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ real_buf[0..n], rel_path });
}

fn writeTestFile(io: std.Io, dir: std.Io.Dir, rel_path: []const u8, content: []const u8) !void {
    var file = try dir.createFile(io, rel_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "loadOrEmptyObject returns empty object for missing config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const path = try testPath(io, tmp.dir, gpa, "missing.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = try loadOrEmptyObject(io, arena.allocator(), path, .{});

    try std.testing.expect(root == .object);
    try std.testing.expectEqual(@as(usize, 0), root.object.count());
}

test "loadOrEmptyObject rejects malformed existing config without force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "bad.json", "{not-json");
    const path = try testPath(io, tmp.dir, gpa, "bad.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidConfigJson,
        loadOrEmptyObject(io, arena.allocator(), path, .{}),
    );
}

test "loadOrEmptyObject replaces malformed config only with force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "bad.json", "{not-json");
    const path = try testPath(io, tmp.dir, gpa, "bad.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = try loadOrEmptyObject(io, arena.allocator(), path, .{ .force = true });

    try std.testing.expect(root == .object);
    try std.testing.expectEqual(@as(usize, 0), root.object.count());
}

test "loadOrEmptyObject rejects empty existing config without force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "empty.json", "");
    const path = try testPath(io, tmp.dir, gpa, "empty.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidConfigJson,
        loadOrEmptyObject(io, arena.allocator(), path, .{}),
    );
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

test "setCodexHooks preserves user hooks on other event names" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var user_obj = std.json.ObjectMap.empty;
    try user_obj.put(aa, "command", std.json.Value{ .string = "/bin/user-codex-hook" });
    var existing_hooks = std.json.ObjectMap.empty;
    try existing_hooks.put(aa, "SessionStart", std.json.Value{ .object = user_obj });

    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = existing_hooks });

    try setCodexHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks").?.object;
    try std.testing.expect(hooks.get("UserPromptSubmit") != null);
    try std.testing.expect(hooks.get("SessionStart") != null);
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

test "setGeminiHooks preserves user hooks on other event names" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var user_obj = std.json.ObjectMap.empty;
    try user_obj.put(aa, "command", std.json.Value{ .string = "/bin/user-gemini-hook" });
    var existing_hooks = std.json.ObjectMap.empty;
    try existing_hooks.put(aa, "BeforeTool", std.json.Value{ .object = user_obj });

    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = existing_hooks });

    try setGeminiHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks").?.object;
    try std.testing.expect(hooks.get("AfterTool") != null);
    try std.testing.expect(hooks.get("BeforeTool") != null);
}

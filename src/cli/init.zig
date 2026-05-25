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
    const crash_after_tmp_write = shouldCrashAfterTmpWrite(environ);

    const has_claude = detectBinary(io, gpa, "claude");
    const has_codex = detectBinary(io, gpa, "codex");
    const has_gemini = detectBinary(io, gpa, "gemini");

    if (!has_claude and !has_codex and !has_gemini) {
        try stdout.interface.writeAll("agit init: no supported agent (claude, codex, gemini) found in PATH.\n");
        try stdout.flush();
        return;
    }

    if (has_claude) {
        try installClaude(io, gpa, home, exe, options, crash_after_tmp_write, &stdout);
    }
    if (has_codex) {
        try installCodex(io, gpa, home, exe, options, crash_after_tmp_write, &stdout);
    }
    if (has_gemini) {
        try installGemini(io, gpa, home, exe, options, crash_after_tmp_write, &stdout);
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

fn shouldCrashAfterTmpWrite(environ: std.process.Environ) bool {
    const raw = environ.getPosix("AGIT_CRASH_AFTER") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "tmp_write");
}

fn installClaude(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    options: InitOptions,
    crash_after_tmp_write: bool,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = try homePath(gpa, home, ".claude/settings.json");
    defer gpa.free(config_path);
    const dir_path = try homePath(gpa, home, ".claude");
    defer gpa.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            reportDirError(io, stdout, "Claude Code", dir_path, err);
            return err;
        },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const loaded = atomic_json_mod.loadObject(io, aa, config_path) catch |err| {
        reportReadError(io, stdout, "Claude Code", config_path, err);
        return err;
    };
    var root = switch (loaded) {
        .missing => std.json.Value{ .object = .empty },
        .object => |value| blk: {
            try backupConfigOrReport(io, aa, config_path, false, stdout);
            break :blk value;
        },
        .malformed => |diag| blk: {
            if (!options.force) {
                reportMalformedConfig(io, stdout, "Claude Code", diag);
                return error.InvalidConfigJson;
            }
            try backupConfigOrReport(io, aa, config_path, true, stdout);
            break :blk std.json.Value{ .object = .empty };
        },
        .not_object => blk: {
            if (!options.force) {
                reportRootNotObject(io, stdout, "Claude Code", config_path);
                return error.ConfigRootNotObject;
            }
            try backupConfigOrReport(io, aa, config_path, true, stdout);
            break :blk std.json.Value{ .object = .empty };
        },
    };
    try setClaudeHooks(aa, &root.object, exe);

    atomic_json_mod.writeAtomic(io, aa, config_path, root, .{
        .crash_after_tmp_write = crash_after_tmp_write,
    }) catch |err| {
        reportWriteError(io, stdout, "Claude Code", config_path, err);
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
    crash_after_tmp_write: bool,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = try homePath(gpa, home, ".codex/hooks.json");
    defer gpa.free(config_path);
    const dir_path = try homePath(gpa, home, ".codex");
    defer gpa.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            reportDirError(io, stdout, "Codex CLI", dir_path, err);
            return err;
        },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const loaded = atomic_json_mod.loadObject(io, aa, config_path) catch |err| {
        reportReadError(io, stdout, "Codex CLI", config_path, err);
        return err;
    };
    var root = switch (loaded) {
        .missing => std.json.Value{ .object = .empty },
        .object => |value| blk: {
            try backupConfigOrReport(io, aa, config_path, false, stdout);
            break :blk value;
        },
        .malformed => |diag| blk: {
            if (!options.force) {
                reportMalformedConfig(io, stdout, "Codex CLI", diag);
                return error.InvalidConfigJson;
            }
            try backupConfigOrReport(io, aa, config_path, true, stdout);
            break :blk std.json.Value{ .object = .empty };
        },
        .not_object => blk: {
            if (!options.force) {
                reportRootNotObject(io, stdout, "Codex CLI", config_path);
                return error.ConfigRootNotObject;
            }
            try backupConfigOrReport(io, aa, config_path, true, stdout);
            break :blk std.json.Value{ .object = .empty };
        },
    };
    try setCodexHooks(aa, &root.object, exe);

    atomic_json_mod.writeAtomic(io, aa, config_path, root, .{
        .crash_after_tmp_write = crash_after_tmp_write,
    }) catch |err| {
        reportWriteError(io, stdout, "Codex CLI", config_path, err);
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
    crash_after_tmp_write: bool,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = try homePath(gpa, home, ".gemini/settings.json");
    defer gpa.free(config_path);
    const dir_path = try homePath(gpa, home, ".gemini");
    defer gpa.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            reportDirError(io, stdout, "Gemini CLI", dir_path, err);
            return err;
        },
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const loaded = atomic_json_mod.loadObject(io, aa, config_path) catch |err| {
        reportReadError(io, stdout, "Gemini CLI", config_path, err);
        return err;
    };
    var root = switch (loaded) {
        .missing => std.json.Value{ .object = .empty },
        .object => |value| blk: {
            try backupConfigOrReport(io, aa, config_path, false, stdout);
            break :blk value;
        },
        .malformed => |diag| blk: {
            if (!options.force) {
                reportMalformedConfig(io, stdout, "Gemini CLI", diag);
                return error.InvalidConfigJson;
            }
            try backupConfigOrReport(io, aa, config_path, true, stdout);
            break :blk std.json.Value{ .object = .empty };
        },
        .not_object => blk: {
            if (!options.force) {
                reportRootNotObject(io, stdout, "Gemini CLI", config_path);
                return error.ConfigRootNotObject;
            }
            try backupConfigOrReport(io, aa, config_path, true, stdout);
            break :blk std.json.Value{ .object = .empty };
        },
    };
    try setGeminiHooks(aa, &root.object, exe);

    atomic_json_mod.writeAtomic(io, aa, config_path, root, .{
        .crash_after_tmp_write = crash_after_tmp_write,
    }) catch |err| {
        reportWriteError(io, stdout, "Gemini CLI", config_path, err);
        return err;
    };

    try stdout.interface.print("agit init: wrote Gemini CLI hooks to {s}\n", .{config_path});
}

fn backupConfigOrReport(
    io: std.Io,
    aa: std.mem.Allocator,
    path: []const u8,
    force: bool,
    stdout: *std.Io.File.Writer,
) !void {
    _ = atomic_json_mod.backupOnce(io, aa, path, force) catch |err| {
        try stdout.interface.print(
            "agit init: failed to back up existing config {s}: {s}\n",
            .{ path, @errorName(err) },
        );
        try stdout.flush();
        return err;
    };
}

fn reportMalformedConfig(
    io: std.Io,
    stdout: *std.Io.File.Writer,
    agent_name: []const u8,
    diag: atomic_json_mod.MalformedJson,
) void {
    stdout.interface.print(
        "agit init: refusing to overwrite {s} config {s}: malformed JSON at offset={d} line={d} column={d}. Fix the JSON or rerun 'agit init --force'.\n",
        .{ agent_name, diag.path, diag.offset, diag.line, diag.column },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportRootNotObject(io: std.Io, stdout: *std.Io.File.Writer, agent_name: []const u8, path: []const u8) void {
    stdout.interface.print(
        "agit init: refusing to overwrite {s} config {s}: JSON root is not an object. Rerun with '--force' to replace it.\n",
        .{ agent_name, path },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportReadError(
    io: std.Io,
    stdout: *std.Io.File.Writer,
    agent_name: []const u8,
    path: []const u8,
    err: anyerror,
) void {
    stdout.interface.print(
        "agit init: failed to read {s} config {s}: {s}\n",
        .{ agent_name, path, @errorName(err) },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportDirError(io: std.Io, stdout: *std.Io.File.Writer, agent_name: []const u8, dir_path: []const u8, err: anyerror) void {
    stdout.interface.print(
        "agit init: failed to create {s} config directory {s}: {s}\n",
        .{ agent_name, dir_path, @errorName(err) },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
}

fn reportWriteError(
    io: std.Io,
    stdout: *std.Io.File.Writer,
    agent_name: []const u8,
    path: []const u8,
    err: anyerror,
) void {
    stdout.interface.print(
        "agit init: failed to write {s} config {s}: {s}\n",
        .{ agent_name, path, @errorName(err) },
    ) catch {};
    stdout.flush() catch {};
    _ = io;
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
    try hooks_obj.put(aa, "UserPromptSubmit", try makeCodexList(aa, exe, "codex-hook"));
    try hooks_obj.put(aa, "PostToolUse", try makeCodexList(aa, exe, "codex-hook"));
    try hooks_obj.put(aa, "Stop", try makeCodexList(aa, exe, "codex-hook"));

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

fn makeCodexList(aa: std.mem.Allocator, exe: []const u8, subcmd: []const u8) !std.json.Value {
    const cmd = try std.mem.concat(aa, u8, &.{ exe, " ", subcmd });
    var handler_obj = std.json.ObjectMap.empty;
    try handler_obj.put(aa, "type", std.json.Value{ .string = "command" });
    try handler_obj.put(aa, "command", std.json.Value{ .string = cmd });

    var handlers = std.json.Array.init(aa);
    try handlers.append(std.json.Value{ .object = handler_obj });

    var group_obj = std.json.ObjectMap.empty;
    try group_obj.put(aa, "hooks", std.json.Value{ .array = handlers });

    var groups = std.json.Array.init(aa);
    try groups.append(std.json.Value{ .object = group_obj });

    return std.json.Value{ .array = groups };
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

    var arr = std.json.Array.init(aa);
    try arr.append(std.json.Value{ .object = obj });
    return std.json.Value{ .array = arr };
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
    const user_prompt = hooks.get("UserPromptSubmit").?;
    try std.testing.expect(user_prompt == .array);
    try std.testing.expectEqual(@as(usize, 1), user_prompt.array.items.len);
    const group = user_prompt.array.items[0];
    try std.testing.expect(group == .object);
    const handlers = group.object.get("hooks") orelse return error.MissingCodexHandlers;
    try std.testing.expect(handlers == .array);
    try std.testing.expectEqual(@as(usize, 1), handlers.array.items.len);
    const handler = handlers.array.items[0];
    try std.testing.expect(handler == .object);
    try std.testing.expectEqualStrings("command", handler.object.get("type").?.string);
    try std.testing.expectEqualStrings("/bin/agit codex-hook", handler.object.get("command").?.string);
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
    try std.testing.expect(hooks.get("AfterTool").?.array.items.len == 1);
    try std.testing.expect(hooks.get("AfterAgent").?.array.items.len == 1);
    try std.testing.expectEqualStrings("/bin/agit", root.get("_agit").?.object.get("binary").?.string);
}

test "setGeminiHooks preserves user hooks on other event names" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var user_obj = std.json.ObjectMap.empty;
    try user_obj.put(aa, "command", std.json.Value{ .string = "/bin/user-gemini-hook" });
    var user_arr = std.json.Array.init(aa);
    try user_arr.append(std.json.Value{ .object = user_obj });

    var existing_hooks = std.json.ObjectMap.empty;
    try existing_hooks.put(aa, "BeforeTool", std.json.Value{ .array = user_arr });

    var root = std.json.ObjectMap.empty;
    try root.put(aa, "hooks", std.json.Value{ .object = existing_hooks });

    try setGeminiHooks(aa, &root, "/bin/agit");

    const hooks = root.get("hooks").?.object;
    try std.testing.expect(hooks.get("AfterTool").?.array.items.len == 1);
    try std.testing.expect(hooks.get("BeforeTool").?.array.items.len == 1);
}

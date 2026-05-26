const std = @import("std");
const exe_path_mod = @import("../util/exe_path.zig");
const home_mod = @import("../util/home.zig");
const atomic_json_mod = @import("../util/atomic_json.zig");
const help_mod = @import("help.zig");
const init_plan_mod = @import("init_plan.zig");
const specs = @import("specs.zig");

pub const usage = specs.init_usage;

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    var options = parseOptions(gpa, iter, &stdout) catch |err| switch (err) {
        error.HelpShown => {
            try stdout.flush();
            return;
        },
        else => return err,
    };
    defer options.deinit();

    const home = try home_mod.getAlloc(gpa, environ);
    defer gpa.free(home);
    const exe = try exe_path_mod.getAlloc(io, gpa);
    defer gpa.free(exe);
    const crash_after_tmp_write = shouldCrashAfterTmpWrite(environ);

    var builder = init_plan_mod.Builder.init(gpa, io, home, exe, options.force, options.dry_run);
    defer builder.deinit();

    // Apply agent selections if any were specified.
    for (options.selected_agents.items) |agent_id| {
        try builder.selectAgent(agent_id);
    }

    const plan = try builder.build();
    defer deinitPlan(gpa, plan);

    if (options.dry_run) {
        try renderPlan(&stdout, plan, home);
        try stdout.flush();
        return;
    }

    // Execute the plan: install only selected agents.
    var any_succeeded = false;
    for (plan.agents) |agent_plan| {
        var found_in_selected = false;
        for (plan.selected_agent_ids) |selected_id| {
            if (std.mem.eql(u8, agent_plan.agent.id, selected_id)) {
                found_in_selected = true;
                break;
            }
        }

        if (!found_in_selected) continue;

        installAgent(io, gpa, agent_plan, exe, options.force, crash_after_tmp_write, &stdout) catch {
            // Continue on error; report at end.
            continue;
        };
        any_succeeded = true;
    }

    if (plan.selected_agent_ids.len > 0 and any_succeeded) {
        try renderSummary(&stdout, plan);
    } else if (plan.selected_agent_ids.len == 0) {
        try stdout.interface.writeAll("agit init: no agents selected or available to install.\n");
    }

    try stdout.flush();
}

const InitOptions = struct {
    force: bool = false,
    dry_run: bool = false,
    selected_agents: std.ArrayList([]const u8),
    gpa: std.mem.Allocator,

    pub fn deinit(self: *InitOptions) void {
        self.selected_agents.deinit(self.gpa);
    }
};

fn parseOptions(gpa: std.mem.Allocator, iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !InitOptions {
    var options = InitOptions{
        .selected_agents = std.ArrayList([]const u8).empty,
        .gpa = gpa,
    };

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            options.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--agent")) {
            const agent_name = iter.next() orelse {
                try stdout.interface.print("error: --agent requires an agent name\n\n", .{});
                try help_mod.renderUsage(stdout, usage);
                try stdout.flush();
                return error.InvalidArgument;
            };
            try options.selected_agents.append(gpa, agent_name);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            return error.HelpShown;
        } else {
            try stdout.interface.print("error: unknown option '{s}'\n\n", .{arg});
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.InvalidArgument;
        }
    }
    return options;
}

fn detectBinary(io: std.Io, gpa: std.mem.Allocator, name: []const u8) bool {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "which", name } }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn deinitPlan(gpa: std.mem.Allocator, plan: init_plan_mod.Plan) void {
    for (plan.agents) |agent_plan| {
        gpa.free(agent_plan.config_path);
        if (agent_plan.backup_path) |backup| {
            gpa.free(backup);
        }
    }
    gpa.free(plan.agents);
    for (plan.selected_agent_ids) |id| {
        gpa.free(id);
    }
    gpa.free(plan.selected_agent_ids);
}

fn shouldCrashAfterTmpWrite(environ: std.process.Environ) bool {
    const raw = environ.getPosix("AGIT_CRASH_AFTER") orelse return false;
    return std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "tmp_write");
}

fn renderPlan(w: *std.Io.File.Writer, plan: init_plan_mod.Plan, _: []const u8) !void {
    try w.interface.writeAll("\nINSTALLATION PLAN (--dry-run)\n");
    try w.interface.writeAll("=============================\n\n");

    // Group agents by state.
    var ready_count: usize = 0;
    var missing_count: usize = 0;
    var malformed_count: usize = 0;
    var not_object_count: usize = 0;

    for (plan.agents) |agent_plan| {
        switch (agent_plan.state) {
            .ready => ready_count += 1,
            .binary_missing => missing_count += 1,
            .config_malformed => malformed_count += 1,
            .config_not_object => not_object_count += 1,
        }
    }

    if (ready_count > 0) {
        try w.interface.print("AGENTS TO INSTALL ({d}):\n", .{ready_count});
        for (plan.agents) |agent_plan| {
            if (agent_plan.state != .ready) continue;
            var selected = false;
            for (plan.selected_agent_ids) |sel_id| {
                if (std.mem.eql(u8, sel_id, agent_plan.agent.id)) {
                    selected = true;
                    break;
                }
            }
            if (!selected) continue;
            try w.interface.print("  ✓ {s}\n", .{agent_plan.agent.name});
            try w.interface.print("    Config: {s}\n", .{agent_plan.config_path});
            if (agent_plan.backup_path) |backup| {
                try w.interface.print("    Backup: {s}\n", .{backup});
            }
        }
        try w.interface.writeAll("\n");
    }

    if (missing_count > 0) {
        try w.interface.print("NOT FOUND ({d}):\n", .{missing_count});
        for (plan.agents) |agent_plan| {
            if (agent_plan.state != .binary_missing) continue;
            try w.interface.print("  ✗ {s} (binary not in PATH)\n", .{agent_plan.agent.name});
        }
        try w.interface.writeAll("\n");
    }

    if (malformed_count > 0) {
        try w.interface.print("MALFORMED CONFIG ({d}):\n", .{malformed_count});
        for (plan.agents) |agent_plan| {
            if (agent_plan.state != .config_malformed) continue;
            const diag = agent_plan.malformed_diag orelse continue;
            try w.interface.print("  ⚠ {s}\n", .{agent_plan.agent.name});
            try w.interface.print("    Path: {s}\n", .{diag.path});
            try w.interface.print("    Error: line {d}, column {d} (offset {d})\n", .{
                diag.line, diag.column, diag.offset,
            });
            try w.interface.print("    Fix: correct the JSON or rerun with --force\n", .{});
        }
        try w.interface.writeAll("\n");
    }

    if (not_object_count > 0) {
        try w.interface.print("ROOT NOT OBJECT ({d}):\n", .{not_object_count});
        for (plan.agents) |agent_plan| {
            if (agent_plan.state != .config_not_object) continue;
            try w.interface.print("  ⚠ {s}\n", .{agent_plan.agent.name});
            try w.interface.print("    Path: {s}\n", .{agent_plan.config_path});
            try w.interface.print("    Note: JSON root is not an object. Rerun with --force to replace it.\n", .{});
        }
        try w.interface.writeAll("\n");
    }

    if (plan.selected_agent_ids.len == 0) {
        try w.interface.writeAll("No agents ready to install.\n\n");
    } else {
        try w.interface.writeAll("To apply, run:\n");
        try w.interface.writeAll("    agit init\n\n");
    }
}

fn renderSummary(w: *std.Io.File.Writer, plan: init_plan_mod.Plan) !void {
    try w.interface.writeAll("\nSETUP COMPLETE\n");
    try w.interface.writeAll("==============\n\n");

    try w.interface.print("Configured agents ({d}):\n", .{plan.selected_agent_ids.len});
    for (plan.agents) |agent_plan| {
        for (plan.selected_agent_ids) |sel_id| {
            if (std.mem.eql(u8, sel_id, agent_plan.agent.id)) {
                try w.interface.print("  ✓ {s}\n", .{agent_plan.agent.name});
                break;
            }
        }
    }
    try w.interface.writeAll("\n");

    // Check for skipped agents and print them.
    var skipped_count: usize = 0;
    for (plan.agents) |agent_plan| {
        if (agent_plan.state == .binary_missing) {
            for (plan.selected_agent_ids) |sel_id| {
                if (std.mem.eql(u8, sel_id, agent_plan.agent.id)) {
                    skipped_count += 1;
                    break;
                }
            }
        }
    }

    if (skipped_count > 0) {
        try w.interface.print("Skipped agents ({d}):\n", .{skipped_count});
        for (plan.agents) |agent_plan| {
            if (agent_plan.state == .binary_missing) {
                for (plan.selected_agent_ids) |sel_id| {
                    if (std.mem.eql(u8, sel_id, agent_plan.agent.id)) {
                        try w.interface.print("  • {s} (binary not found)\n", .{agent_plan.agent.name});
                        break;
                    }
                }
            }
        }
        try w.interface.writeAll("\n");
    }

    try w.interface.writeAll("Next step:\n");
    try w.interface.writeAll("    agit doctor\n\n");
}

fn installAgent(
    io: std.Io,
    gpa: std.mem.Allocator,
    agent_plan: init_plan_mod.AgentPlan,
    exe: []const u8,
    force: bool,
    crash_after_tmp_write: bool,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = agent_plan.config_path;
    const agent_name = agent_plan.agent.name;
    const dir_path = std.fs.path.dirname(config_path) orelse {
        try stdout.interface.print("agit init: invalid config path {s}\n", .{config_path});
        return error.InvalidPath;
    };

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            try stdout.interface.print("agit init: failed to create {s} config directory {s}: {s}\n", .{
                agent_name, dir_path, @errorName(err),
            });
            return err;
        },
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const loaded = atomic_json_mod.loadObject(io, aa, config_path) catch |err| {
        try stdout.interface.print("agit init: failed to read {s} config {s}: {s}\n", .{
            agent_name, config_path, @errorName(err),
        });
        return err;
    };

    var root = switch (loaded) {
        .missing => std.json.Value{ .object = .empty },
        .object => |value| blk: {
            _ = atomic_json_mod.backupOnce(io, aa, config_path, false) catch |err| {
                try stdout.interface.print("agit init: failed to back up existing config {s}: {s}\n", .{
                    config_path, @errorName(err),
                });
                return err;
            };
            break :blk value;
        },
        .malformed => blk: {
            if (!force) {
                if (agent_plan.malformed_diag) |diag| {
                    try stdout.interface.print("agit init: refusing to overwrite {s} config {s}: malformed JSON at offset={d} line={d} column={d}. Fix the JSON or rerun 'agit init --force'.\n", .{
                        agent_name, diag.path, diag.offset, diag.line, diag.column,
                    });
                }
                return error.InvalidConfigJson;
            }
            _ = atomic_json_mod.backupOnce(io, aa, config_path, true) catch |err| {
                try stdout.interface.print("agit init: failed to back up existing config {s}: {s}\n", .{
                    config_path, @errorName(err),
                });
                return err;
            };
            break :blk std.json.Value{ .object = .empty };
        },
        .not_object => blk: {
            if (!force) {
                try stdout.interface.print("agit init: refusing to overwrite {s} config {s}: JSON root is not an object. Rerun with '--force' to replace it.\n", .{
                    agent_name, config_path,
                });
                return error.ConfigRootNotObject;
            }
            _ = atomic_json_mod.backupOnce(io, aa, config_path, true) catch |err| {
                try stdout.interface.print("agit init: failed to back up existing config {s}: {s}\n", .{
                    config_path, @errorName(err),
                });
                return err;
            };
            break :blk std.json.Value{ .object = .empty };
        },
    };

    // Install hooks based on agent type.
    if (std.mem.eql(u8, agent_plan.agent.id, "claude")) {
        try setClaudeHooks(aa, &root.object, exe);
    } else if (std.mem.eql(u8, agent_plan.agent.id, "codex")) {
        try setCodexHooks(aa, &root.object, exe);
    } else if (std.mem.eql(u8, agent_plan.agent.id, "gemini")) {
        try setGeminiHooks(aa, &root.object, exe);
    } else {
        return error.UnknownAgent;
    }

    atomic_json_mod.writeAtomic(io, aa, config_path, root, .{
        .crash_after_tmp_write = crash_after_tmp_write,
    }) catch |err| {
        try stdout.interface.print("agit init: failed to write {s} config {s}: {s}\n", .{
            agent_name, config_path, @errorName(err),
        });
        return err;
    };

    try stdout.interface.print("agit init: wrote {s} hooks to {s}\n", .{ agent_name, config_path });
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

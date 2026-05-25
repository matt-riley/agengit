const std = @import("std");
const hook = @import("hook");

const Agent = enum {
    claude,
    codex,
    gemini,
};

const Options = struct {
    time_ms: u64 = 60_000,
    crash_dir: ?[]u8 = null,
};

const RunSummary = struct {
    iterations: usize = 0,
    failures: usize = 0,
};

const SeedCase = struct {
    label: []const u8,
    data: []const u8,
};

const max_payload_len = 4096;

const claude_seeds = [_]SeedCase{
    .{
        .label = "claude-user",
        .data =
        \\{
        \\  "session_id": "abc123def456",
        \\  "transcript_path": "/Users/user/.claude/projects/-Users-user-myproject/abc123def456.jsonl",
        \\  "cwd": "/Users/user/myproject",
        \\  "permission_mode": "default",
        \\  "hook_event_name": "UserPromptSubmit",
        \\  "prompt": "Write a function to calculate factorial"
        \\}
        ,
    },
    .{
        .label = "claude-tool-batch",
        .data =
        \\{
        \\  "session_id": "abc123def456",
        \\  "transcript_path": "/Users/user/.claude/projects/-Users-user-myproject/abc123def456.jsonl",
        \\  "cwd": "/Users/user/myproject",
        \\  "permission_mode": "default",
        \\  "hook_event_name": "PostToolBatch",
        \\  "tool_calls": [
        \\    {
        \\      "tool_name": "Read",
        \\      "tool_input": { "file_path": "/Users/user/myproject/main.py" },
        \\      "tool_use_id": "toolu_01AbCdEfGhIjKlMnOpQrStUv",
        \\      "tool_response": "1\tfrom __future__ import annotations\n2\t\n3\tdef factorial(n: int) -> int:\n"
        \\    },
        \\    {
        \\      "tool_name": "Bash",
        \\      "tool_input": { "command": "python3 -c 'import math; print(math.factorial(5))'", "timeout": 5000 },
        \\      "tool_use_id": "toolu_02WxYzAbCdEfGhIjKlMnOp",
        \\      "tool_response": "120\n"
        \\    }
        \\  ]
        \\}
        ,
    },
    .{
        .label = "claude-stop",
        .data =
        \\{
        \\  "session_id": "abc123def456",
        \\  "transcript_path": "/Users/user/.claude/projects/-Users-user-myproject/abc123def456.jsonl",
        \\  "cwd": "/Users/user/myproject",
        \\  "permission_mode": "default",
        \\  "hook_event_name": "Stop",
        \\  "stop_hook_active": false,
        \\  "last_assistant_message": "I've implemented the factorial function. It handles edge cases for n=0 and negative numbers, and uses recursion for clarity.",
        \\  "background_tasks": [],
        \\  "session_crons": []
        \\}
        ,
    },
};

const codex_seeds = [_]SeedCase{
    .{
        .label = "codex-user",
        .data =
        \\{
        \\  "session_id": "codex-sess-001",
        \\  "cwd": "/home/user/myproject",
        \\  "hook_event_name": "UserPromptSubmit",
        \\  "prompt": "Refactor the auth module to use JWT tokens"
        \\}
        ,
    },
    .{
        .label = "codex-tool",
        .data =
        \\{
        \\  "session_id": "codex-sess-001",
        \\  "cwd": "/home/user/myproject",
        \\  "hook_event_name": "PostToolUse",
        \\  "tool_name": "bash",
        \\  "tool_input": { "command": "cat src/auth.py" },
        \\  "tool_use_id": "tool-001",
        \\  "tool_response": "import hashlib\n\ndef authenticate(user, password):\n    return hashlib.sha256(password.encode()).hexdigest()\n"
        \\}
        ,
    },
    .{
        .label = "codex-stop",
        .data =
        \\{
        \\  "session_id": "codex-sess-001",
        \\  "cwd": "/home/user/myproject",
        \\  "hook_event_name": "Stop",
        \\  "last_assistant_message": "I've refactored the auth module to use JWT tokens with proper expiry handling."
        \\}
        ,
    },
};

const gemini_seeds = [_]SeedCase{
    .{
        .label = "gemini-tool",
        .data =
        \\{
        \\  "session_id": "gemini-sess-001",
        \\  "cwd": "/home/user/myproject",
        \\  "hook_event_name": "AfterTool",
        \\  "tool_name": "read_file",
        \\  "tool_input": { "path": "src/main.go" },
        \\  "tool_response": "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello, World!\")\n}\n"
        \\}
        ,
    },
    .{
        .label = "gemini-agent",
        .data =
        \\{
        \\  "session_id": "gemini-sess-001",
        \\  "cwd": "/home/user/myproject",
        \\  "hook_event_name": "AfterAgent",
        \\  "response": "I've updated the main.go file to print a personalised greeting based on the hostname."
        \\}
        ,
    },
};

const interesting_tokens = [_][]const u8{
    "\"session_id\"",
    "\"cwd\"",
    "\"hook_event_name\"",
    "\"prompt\"",
    "\"tool_calls\"",
    "\"tool_name\"",
    "\"tool_input\"",
    "\"tool_response\"",
    "\"last_assistant_message\"",
    "\"response\"",
    "\"UserPromptSubmit\"",
    "\"PostToolBatch\"",
    "\"PostToolUse\"",
    "\"Stop\"",
    "\"AfterTool\"",
    "\"AfterAgent\"",
    "{",
    "}",
    "[",
    "]",
    ":",
    ",",
    "\\n",
};

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next();

    const options = parseOptions(init.gpa, &iter) catch |err| {
        try printUsage(&stdout);
        try stdout.flush();
        return err;
    };
    defer if (options.crash_dir) |dir| init.gpa.free(dir);

    if (options.crash_dir) |dir| {
        try std.Io.Dir.cwd().createDirPath(init.io, dir);
    }

    const agents = [_]Agent{ .claude, .codex, .gemini };
    const per_agent_ms = @max(@as(u64, 1), options.time_ms / agents.len);

    var had_failures = false;
    for (agents) |agent| {
        const summary = try runAgentHarness(init.io, init.gpa, agent, per_agent_ms, options.crash_dir);
        try stdout.interface.print(
            "fuzz/{s}: {d} iteration(s), {d} failure(s)\n",
            .{ @tagName(agent), summary.iterations, summary.failures },
        );
        had_failures = had_failures or summary.failures > 0;
    }
    try stdout.flush();

    if (had_failures) return error.FuzzFailures;
}

fn parseOptions(gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !Options {
    var options: Options = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpShown;
        }
        if (std.mem.startsWith(u8, arg, "--time=")) {
            options.time_ms = try parseDurationMillis(arg["--time=".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--crash-dir=")) {
            options.crash_dir = try gpa.dupe(u8, arg["--crash-dir=".len..]);
            continue;
        }
        return error.InvalidArgument;
    }
    return options;
}

fn printUsage(stdout: *std.Io.File.Writer) !void {
    try stdout.interface.writeAll(
        \\usage: zig build fuzz-hooks -- --time=60s [--crash-dir=dist/crash-corpus]
        \\Runs bounded mutational fuzz harnesses for Claude, Codex, and Gemini hook payloads.
        \\
    );
}

fn parseDurationMillis(value: []const u8) !u64 {
    if (value.len == 0) return error.InvalidDuration;
    if (std.mem.endsWith(u8, value, "ms")) {
        return std.fmt.parseInt(u64, value[0 .. value.len - 2], 10);
    }
    const suffix = value[value.len - 1];
    const scalar = switch (suffix) {
        's' => @as(u64, 1_000),
        'm' => @as(u64, 60_000),
        'h' => @as(u64, 3_600_000),
        else => return error.InvalidDuration,
    };
    return try std.math.mul(u64, try std.fmt.parseInt(u64, value[0 .. value.len - 1], 10), scalar);
}

fn runAgentHarness(
    io: std.Io,
    gpa: std.mem.Allocator,
    agent: Agent,
    budget_ms: u64,
    crash_dir: ?[]const u8,
) !RunSummary {
    var prng = std.Random.DefaultPrng.init(seedForAgent(agent));
    const random = prng.random();

    const start_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    const deadline_ms = start_ms + @as(i64, @intCast(budget_ms));

    var summary: RunSummary = .{};
    while (summary.iterations == 0 or std.Io.Timestamp.now(io, .real).toMilliseconds() < deadline_ms) {
        const mutated = try buildMutatedPayload(gpa, agent, random);
        defer gpa.free(mutated);

        validateAgentPayload(agent, gpa, mutated) catch |err| {
            summary.failures += 1;
            if (crash_dir) |dir| {
                try writeCrashInput(io, gpa, dir, agent, summary.iterations, mutated, err);
            }
        };
        summary.iterations += 1;
    }
    return summary;
}

fn seedForAgent(agent: Agent) u64 {
    return switch (agent) {
        .claude => 0xc1a0de0bad5eed,
        .codex => 0xc0de000bad5eed,
        .gemini => 0x6e6d1c0bad5eed,
    };
}

fn seedCases(agent: Agent) []const SeedCase {
    return switch (agent) {
        .claude => &claude_seeds,
        .codex => &codex_seeds,
        .gemini => &gemini_seeds,
    };
}

fn buildMutatedPayload(gpa: std.mem.Allocator, agent: Agent, random: std.Random) ![]u8 {
    const seeds = seedCases(agent);
    const seed = seeds[random.uintLessThan(usize, seeds.len)].data;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, seed);

    const mutation_count = random.intRangeAtMost(u8, 1, 8);
    for (0..mutation_count) |_| {
        switch (random.uintLessThan(u8, 6)) {
            0 => mutateByte(random, &out),
            1 => try insertByte(gpa, random, &out),
            2 => deleteRange(random, &out),
            3 => truncatePayload(random, &out),
            4 => try appendBytes(gpa, random, &out),
            5 => try overlayToken(gpa, random, &out),
            else => unreachable,
        }
    }

    return out.toOwnedSlice(gpa);
}

fn mutateByte(random: std.Random, out: *std.ArrayList(u8)) void {
    if (out.items.len == 0) return;
    const idx = random.uintLessThan(usize, out.items.len);
    out.items[idx] = randomInterestingByte(random);
}

fn insertByte(gpa: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    if (out.items.len >= max_payload_len) return;
    const idx = if (out.items.len == 0) 0 else random.uintLessThan(usize, out.items.len + 1);
    try out.insert(gpa, idx, randomInterestingByte(random));
}

fn deleteRange(random: std.Random, out: *std.ArrayList(u8)) void {
    if (out.items.len == 0) return;
    const start = random.uintLessThan(usize, out.items.len);
    const span = random.intRangeAtMost(usize, 1, @min(@as(usize, 8), out.items.len - start));
    for (0..span) |_| {
        _ = out.orderedRemove(start);
    }
}

fn truncatePayload(random: std.Random, out: *std.ArrayList(u8)) void {
    if (out.items.len == 0) return;
    out.items.len = random.uintLessThan(usize, out.items.len);
}

fn appendBytes(gpa: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    if (out.items.len >= max_payload_len) return;
    const extra_len = random.intRangeAtMost(usize, 1, @min(@as(usize, 12), max_payload_len - out.items.len));
    for (0..extra_len) |_| {
        try out.append(gpa, randomInterestingByte(random));
    }
}

fn overlayToken(gpa: std.mem.Allocator, random: std.Random, out: *std.ArrayList(u8)) !void {
    const token = interesting_tokens[random.uintLessThan(usize, interesting_tokens.len)];
    if (token.len == 0) return;
    if (out.items.len == 0) {
        try out.appendSlice(gpa, token[0..@min(token.len, max_payload_len)]);
        return;
    }

    const start = random.uintLessThan(usize, out.items.len);
    const copy_len = @min(token.len, out.items.len - start);
    @memcpy(out.items[start .. start + copy_len], token[0..copy_len]);

    if (copy_len < token.len and out.items.len < max_payload_len) {
        const remaining = @min(token.len - copy_len, max_payload_len - out.items.len);
        try out.appendSlice(gpa, token[copy_len .. copy_len + remaining]);
    }
}

fn randomInterestingByte(random: std.Random) u8 {
    const bytes =
        "{}[],:\"'\\/._- \n\tabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    return bytes[random.uintLessThan(usize, bytes.len)];
}

fn writeCrashInput(
    io: std.Io,
    gpa: std.mem.Allocator,
    crash_dir: []const u8,
    agent: Agent,
    iteration: usize,
    data: []const u8,
    err: anyerror,
) !void {
    const payload_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{d}.json", .{
        crash_dir,
        @tagName(agent),
        iteration,
    });
    defer gpa.free(payload_path);

    const meta_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{d}.txt", .{
        crash_dir,
        @tagName(agent),
        iteration,
    });
    defer gpa.free(meta_path);

    var payload_file = try std.Io.Dir.cwd().createFile(io, payload_path, .{ .truncate = true });
    defer payload_file.close(io);
    try payload_file.writeStreamingAll(io, data);

    var meta_file = try std.Io.Dir.cwd().createFile(io, meta_path, .{ .truncate = true });
    defer meta_file.close(io);
    try meta_file.writeStreamingAll(io, @errorName(err));
    try meta_file.writeStreamingAll(io, "\n");
}

fn validateAgentPayload(agent: Agent, gpa: std.mem.Allocator, data: []const u8) !void {
    switch (agent) {
        .claude => try validateClaudePayload(gpa, data),
        .codex => try validateCodexPayload(gpa, data),
        .gemini => try validateGeminiPayload(gpa, data),
    }
}

fn validateClaudePayload(gpa: std.mem.Allocator, data: []const u8) !void {
    var diagnostic: hook.Diagnostic = .{};
    const payload_result = try hook.parsePayloadBytes(gpa, data);
    var payload = switch (payload_result) {
        .ok => |ok| ok,
        .err => |parse_err| {
            var parse = parse_err;
            parse.deinit(gpa);
            return;
        },
    };
    defer payload.deinit(gpa);

    const root = hook.requireObject(payload.parsed.value, &diagnostic) catch return;
    _ = hook.requireString(root, "session_id", &diagnostic) catch return;
    const event = hook.requireString(root, "hook_event_name", &diagnostic) catch return;

    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        _ = hook.requireString(root, "cwd", &diagnostic) catch return;
        _ = hook.requireString(root, "prompt", &diagnostic) catch return;
        _ = hook.optionalString(root, "turn_id", &diagnostic) catch return;
        _ = hook.optionalString(root, "event_id", &diagnostic) catch return;
        return;
    }
    if (std.mem.eql(u8, event, "Stop")) {
        _ = hook.requireString(root, "cwd", &diagnostic) catch return;
        _ = hook.optionalString(root, "last_assistant_message", &diagnostic) catch return;
        _ = hook.optionalString(root, "turn_id", &diagnostic) catch return;
        _ = hook.optionalString(root, "event_id", &diagnostic) catch return;
        return;
    }
    if (!std.mem.eql(u8, event, "PostToolBatch")) return;

    _ = hook.requireString(root, "cwd", &diagnostic) catch return;
    _ = hook.optionalString(root, "turn_id", &diagnostic) catch return;

    const tool_calls_val = root.get("tool_calls") orelse return;
    const tool_calls = switch (tool_calls_val) {
        .array => |array| array,
        else => return,
    };

    for (tool_calls.items) |tc| {
        const tc_obj = switch (tc) {
            .object => |object| object,
            else => {
                const malformed = try std.json.Stringify.valueAlloc(gpa, tc, .{});
                defer gpa.free(malformed);
                continue;
            },
        };
        const tool_name = switch (tc_obj.get("tool_name") orelse return) {
            .string => |value| value,
            else => {
                const malformed = try std.json.Stringify.valueAlloc(gpa, tc, .{});
                defer gpa.free(malformed);
                continue;
            },
        };
        _ = tool_name;
        const input_json = try std.json.Stringify.valueAlloc(gpa, tc_obj.get("tool_input") orelse std.json.Value.null, .{});
        defer gpa.free(input_json);
        const response_val = tc_obj.get("tool_response") orelse std.json.Value.null;
        switch (response_val) {
            .string => {},
            else => {
                const response_json = try std.json.Stringify.valueAlloc(gpa, response_val, .{});
                defer gpa.free(response_json);
            },
        }
    }
}

fn validateCodexPayload(gpa: std.mem.Allocator, data: []const u8) !void {
    var diagnostic: hook.Diagnostic = .{};
    const payload_result = try hook.parsePayloadBytes(gpa, data);
    var payload = switch (payload_result) {
        .ok => |ok| ok,
        .err => |parse_err| {
            var parse = parse_err;
            parse.deinit(gpa);
            return;
        },
    };
    defer payload.deinit(gpa);

    const root = hook.requireObject(payload.parsed.value, &diagnostic) catch return;
    _ = hook.requireString(root, "session_id", &diagnostic) catch return;
    _ = hook.requireString(root, "cwd", &diagnostic) catch return;
    const event = hook.requireString(root, "hook_event_name", &diagnostic) catch return;
    _ = hook.optionalString(root, "turn_id", &diagnostic) catch return;
    if (std.mem.eql(u8, event, "PostToolUse")) {
        _ = hook.optionalString(root, "tool_use_id", &diagnostic) catch return;
    } else {
        _ = hook.optionalString(root, "event_id", &diagnostic) catch return;
    }

    if (std.mem.eql(u8, event, "UserPromptSubmit")) {
        _ = hook.requireString(root, "prompt", &diagnostic) catch return;
        return;
    }
    if (std.mem.eql(u8, event, "Stop")) {
        _ = hook.optionalString(root, "last_assistant_message", &diagnostic) catch return;
        return;
    }
    if (!std.mem.eql(u8, event, "PostToolUse")) return;

    const maybe_tool_name = root.get("tool_name");
    if (maybe_tool_name) |value| switch (value) {
        .string => {},
        else => {
            const malformed = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = root }, .{});
            defer gpa.free(malformed);
            return;
        },
    };
    const tool_input_str = try std.json.Stringify.valueAlloc(gpa, root.get("tool_input") orelse std.json.Value.null, .{});
    defer gpa.free(tool_input_str);

    const tool_response = root.get("tool_response") orelse std.json.Value.null;
    switch (tool_response) {
        .string => {},
        else => {
            const response_json = try std.json.Stringify.valueAlloc(gpa, tool_response, .{});
            defer gpa.free(response_json);
        },
    }
}

fn validateGeminiPayload(gpa: std.mem.Allocator, data: []const u8) !void {
    var diagnostic: hook.Diagnostic = .{};
    const payload_result = try hook.parsePayloadBytes(gpa, data);
    var payload = switch (payload_result) {
        .ok => |ok| ok,
        .err => |parse_err| {
            var parse = parse_err;
            parse.deinit(gpa);
            return;
        },
    };
    defer payload.deinit(gpa);

    const root = hook.requireObject(payload.parsed.value, &diagnostic) catch return;
    _ = hook.requireString(root, "session_id", &diagnostic) catch return;
    _ = hook.requireString(root, "cwd", &diagnostic) catch return;
    const event = hook.requireString(root, "hook_event_name", &diagnostic) catch return;
    _ = hook.optionalString(root, "turn_id", &diagnostic) catch return;
    if (std.mem.eql(u8, event, "AfterTool")) {
        _ = hook.optionalString(root, "tool_use_id", &diagnostic) catch return;
    } else {
        _ = hook.optionalString(root, "event_id", &diagnostic) catch return;
    }

    if (std.mem.eql(u8, event, "AfterAgent")) {
        _ = hook.optionalString(root, "response", &diagnostic) catch return;
        return;
    }
    if (!std.mem.eql(u8, event, "AfterTool")) return;

    const maybe_tool_name = root.get("tool_name");
    if (maybe_tool_name) |value| switch (value) {
        .string => {},
        else => {
            const malformed = try std.json.Stringify.valueAlloc(gpa, std.json.Value{ .object = root }, .{});
            defer gpa.free(malformed);
            return;
        },
    };

    const tool_input_str = try std.json.Stringify.valueAlloc(gpa, root.get("tool_input") orelse std.json.Value.null, .{});
    defer gpa.free(tool_input_str);

    const tool_response = root.get("tool_response") orelse std.json.Value.null;
    switch (tool_response) {
        .string => {},
        else => {
            const response_json = try std.json.Stringify.valueAlloc(gpa, tool_response, .{});
            defer gpa.free(response_json);
        },
    }
}

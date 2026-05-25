const std = @import("std");
const store_mod = @import("../store/store.zig");
const exe_path_mod = @import("../util/exe_path.zig");
const home_mod = @import("../util/home.zig");
const file_lock_mod = @import("../util/file_lock.zig");

const DoctorOptions = struct {
    locks: bool = false,
    stats: bool = false,
    last_hook_error: bool = false,
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    var has_failures = false;

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

    // --- Store check ---
    var store = store_mod.Store.open(io, std.Io.Dir.cwd(), gpa) catch |err| {
        try stdout.interface.print("  ✗ .agit/ store: {s}\n", .{@errorName(err)});
        try stdout.flush();
        std.process.exit(1);
    };
    defer store.deinit(io);
    try stdout.interface.writeAll("  ✓ .agit/ store: ok\n");

    const reconcile = try store.reconcile(io, gpa, .dry_run);
    if (reconcile.drifted > 0 or reconcile.index_ahead > 0) {
        has_failures = true;
        try stdout.interface.print(
            "  ✗ ref/index drift: {d} repairable, {d} index-ahead session{s}\n",
            .{
                reconcile.drifted,
                reconcile.index_ahead,
                if (reconcile.drifted + reconcile.index_ahead == 1) "" else "s",
            },
        );
    } else {
        try stdout.interface.writeAll("  ✓ ref/index drift: none detected\n");
    }

    try checkAgitIgnore(io, std.Io.Dir.cwd(), gpa, &stdout);
    try checkStaging(io, gpa, store.root, &stdout);
    if (options.locks) try checkLocks(io, gpa, store.root, &stdout);
    if (options.stats) try printFinalizeStats(&store, &stdout);
    if (options.last_hook_error) try printLastHookError(io, gpa, store.root, &stdout);

    // --- Agent checks ---
    try checkConfigTmpFiles(io, gpa, home, "claude", ".claude/settings.json", &stdout);
    try checkConfigTmpFiles(io, gpa, home, "codex", ".codex/hooks.json", &stdout);
    try checkConfigTmpFiles(io, gpa, home, "gemini", ".gemini/settings.json", &stdout);
    if (!try checkAgent(io, gpa, home, exe, "claude", ".claude/settings.json", &stdout)) has_failures = true;
    if (!try checkAgent(io, gpa, home, exe, "codex", ".codex/hooks.json", &stdout)) has_failures = true;
    if (!try checkAgent(io, gpa, home, exe, "gemini", ".gemini/settings.json", &stdout)) has_failures = true;

    try stdout.flush();
    if (has_failures) std.process.exit(1);
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !DoctorOptions {
    var options: DoctorOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--locks")) {
            options.locks = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            options.stats = true;
        } else if (std.mem.eql(u8, arg, "--last-hook-error")) {
            options.last_hook_error = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printUsage(stdout);
            return error.HelpShown;
        } else {
            try stdout.interface.print("agit doctor: unknown option '{s}'\n\n", .{arg});
            try printUsage(stdout);
            try stdout.flush();
            return error.InvalidArgument;
        }
    }
    return options;
}

fn printUsage(stdout: *std.Io.File.Writer) !void {
    try stdout.interface.writeAll(
        \\Usage: agit doctor [--locks] [--stats] [--last-hook-error]
        \\
        \\Check store health and agent hook configuration.
        \\
        \\Options:
        \\  --locks      List currently held lock files with age and executable path.
        \\  --stats      Print finalize retry/object-write counters.
        \\  --last-hook-error  Pretty-print the newest hook-error log entry.
        \\  -h, --help   Display this help and exit.
        \\
    );
}

fn printFinalizeStats(store: *const store_mod.Store, stdout: *std.Io.File.Writer) !void {
    const retries = try store.index.readMetaCounter(store_mod.finalize_retries_metric_key);
    const objects = try store.index.readMetaCounter(store_mod.finalize_objects_metric_key);
    try stdout.interface.print(
        "  - finalize stats: retries_total={d} objects_written_total={d}\n",
        .{ retries, objects },
    );
}

fn printLastHookError(io: std.Io, gpa: std.mem.Allocator, store_root: std.Io.Dir, stdout: *std.Io.File.Writer) !void {
    const content = store_root.readFileAlloc(io, "log/hook-error.log", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try stdout.interface.writeAll("  - last hook error: none\n");
            return;
        },
        else => return err,
    };
    defer gpa.free(content);

    const line = lastNonEmptyLine(content) orelse {
        try stdout.interface.writeAll("  - last hook error: none\n");
        return;
    };

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{
        .allocate = .alloc_always,
    }) catch {
        try stdout.interface.writeAll("  - last hook error: unreadable JSON entry\n");
        return;
    };
    defer parsed.deinit();

    const pretty = try std.json.Stringify.valueAlloc(gpa, parsed.value, .{ .whitespace = .indent_2 });
    defer gpa.free(pretty);
    try stdout.interface.print("  - last hook error:\n{s}\n", .{pretty});
}

fn lastNonEmptyLine(content: []const u8) ?[]const u8 {
    var end = content.len;
    while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == '\r' or content[end - 1] == ' ' or content[end - 1] == '\t')) : (end -= 1) {}
    if (end == 0) return null;
    const start = (std.mem.lastIndexOfScalar(u8, content[0..end], '\n') orelse 0);
    const raw = if (start == 0) content[0..end] else content[start + 1 .. end];
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    return if (trimmed.len == 0) null else trimmed;
}

fn detectBinary(io: std.Io, gpa: std.mem.Allocator, name: []const u8) bool {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "which", name } }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

const AgitIgnoreDiagnostics = union(enum) {
    missing,
    readable: usize,
    unreadable: anyerror,
};

const StagingDiagnostics = struct {
    pending_json: usize = 0,
    corrupt_json: usize = 0,
    quarantined: usize = 0,
    unreadable: usize = 0,
};

fn checkAgitIgnore(
    io: std.Io,
    repo_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
) !void {
    const diag = try collectAgitIgnoreDiagnostics(io, repo_dir, gpa);
    switch (diag) {
        .missing => try stdout.interface.writeAll("  - .agitignore: not present (using default snapshot skips)\n"),
        .readable => |rule_count| try stdout.interface.print(
            "  ✓ .agitignore: readable ({d} custom rule{s})\n",
            .{ rule_count, if (rule_count == 1) "" else "s" },
        ),
        .unreadable => |err| try stdout.interface.print(
            "  ✗ .agitignore: unreadable ({s}); snapshots fall back to default skips\n",
            .{@errorName(err)},
        ),
    }
}

fn collectAgitIgnoreDiagnostics(
    io: std.Io,
    repo_dir: std.Io.Dir,
    gpa: std.mem.Allocator,
) !AgitIgnoreDiagnostics {
    const data = repo_dir.readFileAlloc(io, ".agitignore", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return .{ .unreadable = err },
    };
    defer gpa.free(data);

    var rule_count: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \r\t"), "/");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        rule_count += 1;
    }
    return .{ .readable = rule_count };
}

fn checkStaging(
    io: std.Io,
    gpa: std.mem.Allocator,
    store_root: std.Io.Dir,
    stdout: *std.Io.File.Writer,
) !void {
    const diag = try collectStagingDiagnostics(io, gpa, store_root);
    if (diag.corrupt_json > 0 or diag.unreadable > 0) {
        try stdout.interface.print(
            "  ✗ .agit/tmp staging: {d} corrupt, {d} unreadable file{s}; inspect .agit/tmp and .agit/log/hook-error.log\n",
            .{ diag.corrupt_json, diag.unreadable, if (diag.corrupt_json + diag.unreadable == 1) "" else "s" },
        );
    } else if (diag.quarantined > 0) {
        try stdout.interface.print(
            "  ✗ .agit/tmp staging: {d} quarantined corrupt file{s}; inspect .agit/tmp\n",
            .{ diag.quarantined, if (diag.quarantined == 1) "" else "s" },
        );
    } else if (diag.pending_json > 0) {
        try stdout.interface.print(
            "  - .agit/tmp staging: {d} pending capture file{s}\n",
            .{ diag.pending_json, if (diag.pending_json == 1) "" else "s" },
        );
    } else {
        try stdout.interface.writeAll("  ✓ .agit/tmp staging: ok\n");
    }
}

fn checkLocks(
    io: std.Io,
    gpa: std.mem.Allocator,
    store_root: std.Io.Dir,
    stdout: *std.Io.File.Writer,
) !void {
    var root_iter_dir = try store_root.openDir(io, ".", .{ .iterate = true });
    defer root_iter_dir.close(io);

    var walker = try root_iter_dir.walk(gpa);
    defer walker.deinit();

    var lock_count: usize = 0;
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".lock")) continue;
        lock_count += 1;

        const data = store_root.readFileAlloc(io, entry.path, gpa, .unlimited) catch {
            try stdout.interface.print("  - lock {s}: unreadable\n", .{entry.path});
            continue;
        };
        defer gpa.free(data);
        const text = std.mem.trim(u8, data, "\n\r ");

        var parsed = std.json.parseFromSlice(file_lock_mod.LockRecord, gpa, text, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            try stdout.interface.print("  - lock {s}: malformed\n", .{entry.path});
            continue;
        };
        defer parsed.deinit();

        const age_ms: i64 = @max(0, now_ms - parsed.value.started_at);
        try stdout.interface.print(
            "  - lock {s}: age_ms={d} pid={d} exe={s}\n",
            .{ entry.path, age_ms, parsed.value.pid, parsed.value.exe_path },
        );
    }

    if (lock_count == 0) {
        try stdout.interface.writeAll("  ✓ .agit locks: none held\n");
    }
}

fn collectStagingDiagnostics(
    io: std.Io,
    gpa: std.mem.Allocator,
    store_root: std.Io.Dir,
) !StagingDiagnostics {
    var tmp_dir = store_root.openDir(io, "tmp", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .{},
        else => return err,
    };
    defer tmp_dir.close(io);

    var walker = try tmp_dir.walk(gpa);
    defer walker.deinit();

    var diag: StagingDiagnostics = .{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".json.lock")) continue;
        if (std.mem.endsWith(u8, entry.path, ".json.corrupt") or
            std.mem.endsWith(u8, entry.path, ".corrupt"))
        {
            diag.quarantined += 1;
            continue;
        }
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

        const data = tmp_dir.readFileAlloc(io, entry.path, gpa, .unlimited) catch {
            diag.unreadable += 1;
            continue;
        };
        defer gpa.free(data);

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{
            .allocate = .alloc_always,
        }) catch {
            diag.corrupt_json += 1;
            continue;
        };
        defer parsed.deinit();
        diag.pending_json += 1;
    }
    return diag;
}

fn checkAgent(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    agent_name: []const u8,
    rel_config: []const u8,
    stdout: *std.Io.File.Writer,
) !bool {
    const has_bin = detectBinary(io, gpa, agent_name);
    if (!has_bin) {
        try stdout.interface.print("  - {s}: not installed\n", .{agent_name});
        return true;
    }
    try stdout.interface.print("  ✓ {s}: binary found\n", .{agent_name});

    const config_path = try std.mem.concat(gpa, u8, &.{ home, "/", rel_config });
    defer gpa.free(config_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const text = (readFileAllocOrNull(io, aa, config_path) catch |err| {
        try stdout.interface.print("  ✗ {s}: config unreadable ({s}): {s}\n", .{ agent_name, config_path, @errorName(err) });
        return false;
    }) orelse {
        try stdout.interface.print("  ✗ {s}: config not found ({s})\n", .{ agent_name, config_path });
        return false;
    };

    const root_val = std.json.parseFromSliceLeaky(std.json.Value, aa, text, .{
        .allocate = .alloc_always,
    }) catch {
        try stdout.interface.print("  ✗ {s}: config not valid JSON ({s})\n", .{ agent_name, config_path });
        return false;
    };

    if (root_val != .object) {
        try stdout.interface.print("  ✗ {s}: config root is not an object\n", .{agent_name});
        return false;
    }

    const agit = root_val.object.get("_agit");
    if (agit == null or agit.? != .object) {
        try stdout.interface.print("  ✗ {s}: agit not initialized (no _agit metadata)\n", .{agent_name});
        return false;
    }

    const bin_val = agit.?.object.get("binary");
    if (bin_val == null or bin_val.? != .string) {
        try stdout.interface.print("  ✗ {s}: _agit.binary missing\n", .{agent_name});
        return false;
    }

    const stored = bin_val.?.string;
    if (std.mem.eql(u8, stored, exe)) {
        try stdout.interface.print("  ✓ {s}: hooks configured (binary matches)\n", .{agent_name});
        return true;
    } else {
        try stdout.interface.print(
            "  ✗ {s}: binary mismatch (config has {s}, current is {s})\n",
            .{ agent_name, stored, exe },
        );
        return false;
    }
}

fn checkConfigTmpFiles(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    agent_name: []const u8,
    rel_config: []const u8,
    stdout: *std.Io.File.Writer,
) !void {
    const rel_dir = std.fs.path.dirname(rel_config) orelse return;
    const file_base = std.fs.path.basename(rel_config);
    const prefix = try std.fmt.allocPrint(gpa, "{s}.agit-tmp-", .{file_base});
    defer gpa.free(prefix);

    const dir_path = try std.mem.concat(gpa, u8, &.{ home, "/", rel_dir });
    defer gpa.free(dir_path);

    var config_dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => {
            try stdout.interface.print(
                "  - {s}: unable to scan temp config files in {s} ({s})\n",
                .{ agent_name, dir_path, @errorName(err) },
            );
            return;
        },
    };
    defer config_dir.close(io);

    var walker = try config_dir.walk(gpa);
    defer walker.deinit();

    var leftover_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const name = std.fs.path.basename(entry.path);
        if (std.mem.startsWith(u8, name, prefix)) leftover_count += 1;
    }

    if (leftover_count > 0) {
        try stdout.interface.print(
            "  ✗ {s}: found {d} crash-temp file{s} matching {s}* in {s}\n",
            .{
                agent_name,
                leftover_count,
                if (leftover_count == 1) "" else "s",
                prefix,
                dir_path,
            },
        );
    }
}

fn readFileAllocOrNull(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
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

fn writeTestFile(io: std.Io, dir: std.Io.Dir, rel_path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |sep| {
        try dir.createDirPath(io, rel_path[0..sep]);
    }
    var file = try dir.createFile(io, rel_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "collectAgitIgnoreDiagnostics reports missing and readable files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const missing = try collectAgitIgnoreDiagnostics(io, tmp.dir, gpa);
    try std.testing.expect(missing == .missing);

    try writeTestFile(io, tmp.dir, ".agitignore", "# comment\n\n*.log\nbuild_*/\n");
    const diag = try collectAgitIgnoreDiagnostics(io, tmp.dir, gpa);
    try std.testing.expect(diag == .readable);
    try std.testing.expectEqual(@as(usize, 2), diag.readable);
}

test "collectStagingDiagnostics counts pending corrupt and quarantined files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "tmp/good.json", "{}");
    try writeTestFile(io, tmp.dir, "tmp/bad.json", "{not-json");
    try writeTestFile(io, tmp.dir, "tmp/old.json.corrupt", "{not-json");
    try writeTestFile(io, tmp.dir, "tmp/good.json.lock", "");

    const diag = try collectStagingDiagnostics(io, gpa, tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), diag.pending_json);
    try std.testing.expectEqual(@as(usize, 1), diag.corrupt_json);
    try std.testing.expectEqual(@as(usize, 1), diag.quarantined);
    try std.testing.expectEqual(@as(usize, 0), diag.unreadable);
}

test "lastNonEmptyLine returns final JSONL entry" {
    const input =
        \\{"one":1}
        \\{"two":2}
        \\
    ;
    const line = lastNonEmptyLine(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("{\"two\":2}", line);
}

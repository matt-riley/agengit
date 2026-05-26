const std = @import("std");
const config_mod = @import("../store/config.zig");
const exe_path_mod = @import("../util/exe_path.zig");
const home_mod = @import("../util/home.zig");
const init_plan_mod = @import("init_plan.zig");
const store_mod = @import("../store/store.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");

pub const usage = specs.status_usage;

const stale_staging_grace_ms: i64 = 2 * 60 * 60 * 1000;

const StatusOptions = struct {
    format: output_mod.Format = .human,
};

const LatestCapture = struct {
    hash: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    timestamp: i64,
};

const WarningSummary = struct {
    stale_staging_files: usize = 0,
    quarantined_staging_files: usize = 0,

    fn total(self: WarningSummary) usize {
        return self.stale_staging_files + self.quarantined_staging_files;
    }
};

const AgentSummary = struct {
    ids: []const []const u8 = &.{},
    unavailable_reason: ?[]const u8 = null,

    fn deinit(self: *AgentSummary, gpa: std.mem.Allocator) void {
        for (self.ids) |id| gpa.free(@constCast(id));
        if (self.ids.len > 0) gpa.free(self.ids);
        if (self.unavailable_reason) |reason| gpa.free(reason);
        self.* = undefined;
    }
};

/// Format a millisecond-precision Unix timestamp as "YYYY-MM-DD HH:MM:SS".
pub fn formatTimestamp(ms: i64, buf: *[32]u8) []const u8 {
    if (ms <= 0) return "(unknown)";
    const secs: u64 = @intCast(@max(0, @divTrunc(ms, 1000)));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const eday = es.getEpochDay();
    const yd = eday.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    var store = try openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    const sessions_count = try store.index.countSessions();
    const steps_count = try store.index.countSteps();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try store.root.realPath(io, &path_buf);
    const store_path = try gpa.dupe(u8, path_buf[0..path_len]);
    defer gpa.free(store_path);

    const latest_capture = try loadLatestCapture(gpa, &store);
    defer if (latest_capture) |capture| deinitLatestCapture(gpa, capture);

    const warnings = try collectWarnings(io, &store);

    var agent_summary = try collectConfiguredAgents(io, gpa, environ);
    defer agent_summary.deinit(gpa);

    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa);
    defer loaded_config.deinit();

    const next_step = chooseNextStep(steps_count, warnings, agent_summary);

    switch (options.format) {
        .human => try writeHuman(
            &stdout,
            store_path,
            latest_capture,
            sessions_count,
            steps_count,
            warnings,
            &agent_summary,
            loaded_config.value.privacy.display.redacted_by_default,
            next_step,
        ),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .store_path = store_path,
            .latest_capture = latest_capture,
            .sessions = sessions_count,
            .steps = steps_count,
            .warnings = .{
                .stale_staging_files = warnings.stale_staging_files,
                .quarantined_staging_files = warnings.quarantined_staging_files,
                .total = warnings.total(),
            },
            .configured_agents = agent_summary.ids,
            .configured_agents_error = agent_summary.unavailable_reason,
            .privacy = .{
                .display_redacted_by_default = loaded_config.value.privacy.display.redacted_by_default,
            },
            .next_step = next_step,
        }),
    }
    try stdout.flush();
}

fn writeHuman(
    stdout: *std.Io.File.Writer,
    store_path: []const u8,
    latest_capture: ?LatestCapture,
    sessions_count: i64,
    steps_count: i64,
    warnings: WarningSummary,
    agent_summary: *const AgentSummary,
    display_redacted_by_default: bool,
    next_step: []const u8,
) !void {
    try stdout.interface.print("Store path:      {s}\n", .{store_path});

    var ts_buf: [32]u8 = undefined;
    if (latest_capture) |capture| {
        try stdout.interface.print("Latest capture:  {s}  {s}/{s}  turn {s}  step {s}\n", .{
            formatTimestamp(capture.timestamp, &ts_buf),
            capture.origin,
            capture.session_id,
            capture.turn_id,
            capture.hash[0..@min(12, capture.hash.len)],
        });
    } else {
        try stdout.interface.writeAll("Latest capture:  (none)\n");
    }

    try stdout.interface.print("Sessions:        {d}\n", .{sessions_count});
    try stdout.interface.print("Steps:           {d}\n", .{steps_count});

    if (warnings.total() == 0) {
        try stdout.interface.writeAll("Warnings:        none\n");
    } else {
        try stdout.interface.print("Warnings:        stale staging={d}, quarantined staging={d}\n", .{
            warnings.stale_staging_files,
            warnings.quarantined_staging_files,
        });
    }

    if (agent_summary.unavailable_reason) |reason| {
        try stdout.interface.print("Configured agents: unavailable ({s})\n", .{reason});
    } else if (agent_summary.ids.len == 0) {
        try stdout.interface.writeAll("Configured agents: (none)\n");
    } else {
        try stdout.interface.writeAll("Configured agents: ");
        for (agent_summary.ids, 0..) |agent_id, i| {
            if (i > 0) try stdout.interface.writeAll(", ");
            try stdout.interface.writeAll(agent_id);
        }
        try stdout.interface.writeAll("\n");
    }

    try stdout.interface.print("Privacy display: {s}\n", .{
        if (display_redacted_by_default) "redacted by default" else "full by default",
    });
    try stdout.interface.print("Next step:       {s}\n", .{next_step});
}

fn collectWarnings(io: std.Io, store: *store_mod.Store) !WarningSummary {
    var summary: WarningSummary = .{};
    var tmp_dir = store.root.openDir(io, "tmp", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return summary,
        else => return err,
    };
    defer tmp_dir.close(io);

    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
    var iter = tmp_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".json.corrupt") or std.mem.endsWith(u8, entry.name, ".corrupt")) {
            summary.quarantined_staging_files += 1;
            continue;
        }
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (std.mem.endsWith(u8, entry.name, ".json.lock")) continue;

        const stat = try tmp_dir.statFile(io, entry.name, .{});
        const age_ms: i64 = @max(0, now_ms - stat.mtime.toMilliseconds());
        if (age_ms >= stale_staging_grace_ms) summary.stale_staging_files += 1;
    }
    return summary;
}

fn collectConfiguredAgents(io: std.Io, gpa: std.mem.Allocator, environ: std.process.Environ) !AgentSummary {
    const home = home_mod.getAlloc(gpa, environ) catch |err| {
        return .{
            .unavailable_reason = try gpa.dupe(u8, @errorName(err)),
        };
    };
    defer gpa.free(home);

    const exe = exe_path_mod.getAlloc(io, gpa) catch |err| {
        return .{
            .unavailable_reason = try gpa.dupe(u8, @errorName(err)),
        };
    };
    defer gpa.free(exe);

    var configured: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (configured.items) |agent_id| gpa.free(agent_id);
        configured.deinit(gpa);
    }

    for (init_plan_mod.all()) |agent| {
        if (try agentConfiguredForBinary(io, gpa, home, exe, agent.config_path_rel)) {
            try configured.append(gpa, try gpa.dupe(u8, agent.id));
        }
    }

    return .{
        .ids = try configured.toOwnedSlice(gpa),
    };
}

fn agentConfiguredForBinary(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    rel_config: []const u8,
) !bool {
    const config_path = try std.mem.concat(gpa, u8, &.{ home, "/", rel_config });
    defer gpa.free(config_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const text = readFileAllocOrNull(io, scratch, config_path) catch return false;
    if (text == null) return false;

    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, text.?, .{
        .allocate = .alloc_always,
    }) catch return false;
    if (root != .object) return false;

    const agit_meta = root.object.get("_agit") orelse return false;
    if (agit_meta != .object) return false;
    const stored_binary = agit_meta.object.get("binary") orelse return false;
    if (stored_binary != .string) return false;
    return std.mem.eql(u8, stored_binary.string, exe);
}

fn readFileAllocOrNull(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn loadLatestCapture(gpa: std.mem.Allocator, store: *store_mod.Store) !?LatestCapture {
    const row = try store.index.mostRecentStep(gpa) orelse return null;
    return .{
        .hash = row.hash,
        .origin = row.origin,
        .session_id = row.session_id,
        .turn_id = row.turn_id,
        .timestamp = row.timestamp,
    };
}

fn deinitLatestCapture(gpa: std.mem.Allocator, capture: LatestCapture) void {
    gpa.free(capture.hash);
    gpa.free(capture.origin);
    gpa.free(capture.session_id);
    gpa.free(capture.turn_id);
}

fn chooseNextStep(steps_count: i64, warnings: WarningSummary, agent_summary: AgentSummary) []const u8 {
    if (warnings.total() > 0) return "Run `agit doctor` to inspect stale staging or hook errors.";
    if (steps_count > 0) return "Run `agit timeline` to inspect recent recorded steps.";
    if (agent_summary.unavailable_reason != null or agent_summary.ids.len == 0) {
        return "Run `agit init` to configure hooks before capturing activity.";
    }
    return "Record some agent activity, then run `agit timeline`.";
}

pub fn openStoreOrExit(
    io: std.Io,
    gpa: std.mem.Allocator,
    writer: *std.Io.File.Writer,
    format: output_mod.Format,
    command_name: []const u8,
) !store_mod.Store {
    return store_mod.Store.findAndOpen(io, std.Io.Dir.cwd(), gpa) catch |err| {
        switch (err) {
            error.StoreNotFound => try writeDiagnostic(writer, format, command_name, .{
                .code = "store_not_found",
                .message = "Not an agit repository.",
                .hint = "Run `agit init` from the repository root to start recording.",
                .path = ".",
            }),
            else => try writeDiagnostic(writer, format, command_name, .{
                .code = "store_open_failed",
                .message = "Failed to open agit store.",
                .hint = @errorName(err),
                .path = ".",
            }),
        }
        try writer.flush();
        std.process.exit(1);
    };
}

pub fn writeDiagnostic(
    writer: *std.Io.File.Writer,
    format: output_mod.Format,
    command_name: []const u8,
    diagnostic: output_mod.Diagnostic,
) !void {
    switch (format) {
        .human => {
            if (std.mem.eql(u8, diagnostic.code, "store_not_found")) {
                try help_mod.renderRepoNotFound(writer.interface, diagnostic.path orelse ".");
                return;
            }
            try writer.interface.print("error: {s}\n", .{diagnostic.message});
            if (diagnostic.hint) |hint| {
                try writer.interface.print("hint: {s}\n", .{hint});
            }
            if (diagnostic.candidates) |candidates| {
                try writer.interface.writeAll("candidates:\n");
                for (candidates) |candidate| {
                    try writer.interface.print("  - {s}\n", .{candidate});
                }
            }
        },
        .json => try output_mod.writeDiagnosticEnvelope(writer, command_name, diagnostic),
    }
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !StatusOptions {
    var options: StatusOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            try writeDiagnostic(stdout, options.format, usage.name, .{
                .code = "invalid_argument",
                .message = "Unknown option.",
                .hint = arg,
            });
            if (options.format == .human) {
                try stdout.interface.writeAll("\n");
                try help_mod.renderUsage(stdout, usage);
            }
            try stdout.flush();
            std.process.exit(1);
        }
    }
    return options;
}

test "formatTimestamp epoch zero" {
    var buf: [32]u8 = undefined;
    const s = formatTimestamp(0, &buf);
    try std.testing.expectEqualStrings("(unknown)", s);
}

test "formatTimestamp known date" {
    var buf: [32]u8 = undefined;
    const s = formatTimestamp(1704067200000, &buf);
    try std.testing.expectEqualStrings("2024-01-01 00:00:00", s);
}

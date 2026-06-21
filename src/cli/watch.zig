const std = @import("std");
const config_mod = @import("../store/config.zig");
const date_util = @import("../util/date.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const shared = @import("shared.zig");
const specs = @import("specs.zig");
const status = @import("status.zig");
const step_line = @import("step_line.zig");
const store_mod = @import("../store/store.zig");
const arg_parse = @import("arg_parse.zig");

pub const usage = specs.watch_usage;

const default_interval_ms: u64 = 1000;
const min_interval_ms: u64 = 50;
const max_interval_ms: u64 = 60 * 60 * 1000;
const sleep_slice_ms: u64 = 50;
const batch_limit: usize = 100;

var stop_requested = std.atomic.Value(bool).init(false);

const WatchOptions = struct {
    origin: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,
    since_raw: ?[:0]const u8 = null,
    since_ms: ?i64 = null,
    interval_ms: u64 = default_interval_ms,
    redaction_mode: shared.RedactionMode = .auto,
    format: output_mod.Format = .human,
};

const SignalGuards = struct {
    old_int: std.posix.Sigaction,
    old_term: std.posix.Sigaction,

    fn restore(self: SignalGuards) void {
        std.posix.sigaction(.INT, &self.old_int, null);
        std.posix.sigaction(.TERM, &self.old_term, null);
    }
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        error.InvalidArgument => return,
        else => return err,
    };

    const session_filter = try resolveSessionFilter(&stdout, options);

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);
    try store.index.db.execNoArgs("pragma busy_timeout = 250");

    var setup = try shared.loadQuerySetup(io, gpa, &store, &stdout, options.format, usage.name, options.redaction_mode);
    defer setup.deinit();

    stop_requested.store(false, .release);
    const guards = installStopHandlers();
    defer guards.restore();

    var cursor_rowid: i64 = if (options.since_ms == null)
        (try store.index.latestWatchRowid(.{
            .origin = session_filter.origin,
            .session_id = session_filter.session_id,
            .after_rowid = 0,
            .limit = batch_limit,
        })) orelse 0
    else
        0;

    var watched_count: usize = 0;
    while (!stop_requested.load(.acquire)) {
        while (!stop_requested.load(.acquire)) {
            const rows = store.index.listStepsAfterCursor(gpa, .{
                .origin = session_filter.origin,
                .session_id = session_filter.session_id,
                .since_ms = options.since_ms,
                .after_rowid = cursor_rowid,
                .limit = batch_limit,
            }) catch |err| {
                try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                    .code = "watch_query_failed",
                    .message = "Failed to query newly recorded steps.",
                    .hint = @errorName(err),
                });
                try stdout.flush();
                std.process.exit(1);
            };
            defer store_mod.freeTimelineRows(gpa, rows);

            if (rows.len == 0) break;
            for (rows) |row| {
                if (stop_requested.load(.acquire)) break;
                try writeRow(io, gpa, &stdout, &store, row, options.format, setup.use_redaction, setup.config.value.privacy.custom_literals);
                cursor_rowid = row.rowid;
                watched_count += 1;
                try stdout.flush();
            }
            if (rows.len < batch_limit) break;
        }
        if (!stop_requested.load(.acquire)) try sleepWithStopChecks(io, options.interval_ms);
    }

    try writeSummary(&stdout, options.format, watched_count);
    try stdout.flush();
}

fn writeRow(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    row: store_mod.TimelineRow,
    format: output_mod.Format,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !void {
    switch (format) {
        .human => try step_line.writeHumanRow(io, gpa, stdout, store, row, usage.name, use_redaction, custom_literals),
        .json => {
            const preview = try step_line.previewAllocForRow(
                io,
                gpa,
                stdout,
                .json,
                store,
                row,
                usage.name,
                use_redaction,
                custom_literals,
            );
            defer gpa.free(preview);
            try output_mod.writeEnvelope(stdout, usage.name, .{ .event = "step", .step = .{
                .hash = row.hash,
                .origin = row.origin,
                .session_id = row.session_id,
                .turn_id = row.turn_id,
                .timestamp = row.timestamp,
                .preview = preview,
                .git_commit = row.git_commit,
                .git_branch = row.git_branch,
                .git_dirty = row.git_dirty,
            } });
        },
    }
}

fn writeSummary(stdout: *std.Io.File.Writer, format: output_mod.Format, watched_count: usize) !void {
    switch (format) {
        .human => try stdout.interface.print("Watched {d} step{s}.\n", .{ watched_count, if (watched_count == 1) "" else "s" }),
        .json => try output_mod.writeEnvelope(stdout, usage.name, .{ .event = "summary", .steps = watched_count }),
    }
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !WatchOptions {
    var options: WatchOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--origin")) {
            options.origin = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--origin requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--session")) {
            options.session = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--session requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--since")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--since requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.since_ms = date_util.parseUtcDateMidnight(value) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --since date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.since_raw = value;
        } else if (std.mem.eql(u8, arg, "--interval")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--interval requires a value like 1s or 250ms.");
                return error.InvalidArgument;
            };
            options.interval_ms = parseIntervalMs(value) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --interval value; use 50ms..3600s.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--redacted")) {
            options.redaction_mode = .redacted;
        } else if (std.mem.eql(u8, arg, "--full")) {
            options.redaction_mode = .full;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            try arg_parse.invalidArg(stdout, options.format, usage, "Unexpected argument.");
            return error.InvalidArgument;
        }
    }
    return options;
}

fn parseIntervalMs(value: []const u8) !u64 {
    const raw_ms = if (std.mem.endsWith(u8, value, "ms"))
        try std.fmt.parseUnsigned(u64, value[0 .. value.len - 2], 10)
    else if (std.mem.endsWith(u8, value, "s"))
        try std.math.mul(u64, try std.fmt.parseUnsigned(u64, value[0 .. value.len - 1], 10), 1000)
    else
        try std.fmt.parseUnsigned(u64, value, 10);

    if (raw_ms < min_interval_ms or raw_ms > max_interval_ms) return error.InvalidInterval;
    return raw_ms;
}

fn resolveSessionFilter(stdout: *std.Io.File.Writer, options: WatchOptions) !shared.SessionFilter {
    return shared.resolveSessionFilter(stdout, options.format, usage.name, options.origin, options.session) catch |err| switch (err) {
        error.InvalidArgument => {
            try stdout.interface.writeAll("\n");
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return err;
        },
        else => return err,
    };
}

fn installStopHandlers() SignalGuards {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old_int: std.posix.Sigaction = undefined;
    var old_term: std.posix.Sigaction = undefined;
    std.posix.sigaction(.INT, &act, &old_int);
    std.posix.sigaction(.TERM, &act, &old_term);
    return .{ .old_int = old_int, .old_term = old_term };
}

fn handleStopSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .release);
}

fn sleepWithStopChecks(io: std.Io, interval_ms: u64) !void {
    var remaining = interval_ms;
    while (remaining > 0 and !stop_requested.load(.acquire)) {
        const chunk = @min(remaining, sleep_slice_ms);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(chunk)), .awake) catch |err| switch (err) {
            error.Canceled => {},
        };
        remaining -= chunk;
    }
}

test "parse watch intervals" {
    try std.testing.expectEqual(@as(u64, 50), try parseIntervalMs("50ms"));
    try std.testing.expectEqual(@as(u64, 1000), try parseIntervalMs("1s"));
    try std.testing.expectEqual(@as(u64, 250), try parseIntervalMs("250"));
    try std.testing.expectError(error.InvalidInterval, parseIntervalMs("0"));
}

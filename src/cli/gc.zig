const std = @import("std");

const gc_mod = @import("../store/gc.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const reindex_cmd = @import("reindex.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");
const store_mod = @import("../store/store.zig");

pub const usage = specs.gc_usage;

const Options = struct {
    json: bool = false,
    grace_hours: u64 = 2,
    prune_before_ms: ?i64 = null,
    prune_before_raw: ?[]const u8 = null,
};

const GcStatsEnvelope = struct {
    grace_hours: u64,
    prune_before: ?[]const u8,
    refs_pruned: usize,
    objects_pruned: usize,
    object_bytes_pruned: u64,
    tmp_files_pruned: usize,
    log_rotated: bool,
    reindexed: bool,
    optimized_index: bool,
    reachable_objects: usize,
    reachable_bytes: u64,
    total_objects_before: usize,
    total_bytes_before: u64,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => {
            try stdout.flush();
            return;
        },
        else => return err,
    };

    var repo_dir = store_mod.Store.findRoot(io, std.Io.Dir.cwd()) catch |err| switch (err) {
        error.StoreNotFound => {
            try status_cmd.writeDiagnostic(&stdout, if (options.json) .json else .human, usage.name, .{
                .code = "store_not_found",
                .message = "Not an agit repository.",
                .hint = "Run `agit init` from the repository root to start recording.",
                .path = ".",
            });
            try stdout.flush();
            std.process.exit(1);
        },
        else => return err,
    };
    defer repo_dir.close(io);

    var store = try store_mod.Store.openWithOptions(io, repo_dir, gpa, .{ .reconcile = false });
    defer store.deinit(io);

    const grace_period_ms = try gracePeriodMs(options.grace_hours);
    var result = try gc_mod.run(io, gpa, &store, .{
        .grace_period_ms = grace_period_ms,
        .prune_before_ms = options.prune_before_ms,
    });
    defer result.deinit(gpa);

    if (result.busy_lock) |busy| {
        try status_cmd.writeDiagnostic(&stdout, if (options.json) .json else .human, usage.name, .{
            .code = "store_busy",
            .message = "Refusing to run gc while the store appears active.",
            .hint = busy.path,
            .path = busy.path,
        });
        try stdout.flush();
        std.process.exit(1);
    }

    var reindexed = false;
    var optimized_index = false;
    if (result.reindex_needed) {
        try store.index.truncate();
        _ = try reindex_cmd.reindex(io, gpa, &store);
        try store.index.db.execNoArgs("vacuum");
        try store.index.db.execNoArgs("analyze");
        reindexed = true;
        optimized_index = true;
    }

    if (options.json) {
        try output_mod.writeEnvelope(&stdout, usage.name, GcStatsEnvelope{
            .grace_hours = options.grace_hours,
            .prune_before = options.prune_before_raw,
            .refs_pruned = result.refs_pruned,
            .objects_pruned = result.objects_pruned,
            .object_bytes_pruned = result.object_bytes_pruned,
            .tmp_files_pruned = result.tmp_files_pruned,
            .log_rotated = result.log_rotated,
            .reindexed = reindexed,
            .optimized_index = optimized_index,
            .reachable_objects = result.reachable_objects,
            .reachable_bytes = result.reachable_bytes,
            .total_objects_before = result.total_objects_before,
            .total_bytes_before = result.total_bytes_before,
        });
    } else {
        try stdout.interface.print(
            "gc: refs_pruned={d} objects_pruned={d} bytes_pruned={d} tmp_files_pruned={d} log_rotated={s} reindexed={s}\n",
            .{
                result.refs_pruned,
                result.objects_pruned,
                result.object_bytes_pruned,
                result.tmp_files_pruned,
                if (result.log_rotated) "yes" else "no",
                if (reindexed) "yes" else "no",
            },
        );
        try stdout.interface.print(
            "    reachable={d}/{d} objects bytes={d}/{d}\n",
            .{
                result.reachable_objects,
                result.total_objects_before,
                result.reachable_bytes,
                result.total_bytes_before,
            },
        );
    }
    try stdout.flush();
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !Options {
    var options: Options = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--grace-hours")) {
            const value = iter.next() orelse return invalidArgument(stdout, options.json, "--grace-hours requires an integer value.");
            options.grace_hours = std.fmt.parseUnsigned(u64, value, 10) catch {
                return invalidArgument(stdout, options.json, "Invalid --grace-hours value.");
            };
        } else if (std.mem.eql(u8, arg, "--prune-before")) {
            const value = iter.next() orelse return invalidArgument(stdout, options.json, "--prune-before requires a YYYY-MM-DD value.");
            options.prune_before_ms = parseUtcDateMidnight(value) catch {
                return invalidArgument(stdout, options.json, "Invalid --prune-before date; use YYYY-MM-DD.");
            };
            options.prune_before_raw = value;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            return error.HelpShown;
        } else {
            try status_cmd.writeDiagnostic(stdout, if (options.json) .json else .human, usage.name, .{
                .code = "invalid_argument",
                .message = "Unknown option.",
                .hint = arg,
            });
            if (!options.json) {
                try stdout.interface.writeAll("\n");
                try help_mod.renderUsage(stdout, usage);
            }
            try stdout.flush();
            std.process.exit(1);
        }
    }
    return options;
}

fn invalidArgument(stdout: *std.Io.File.Writer, json: bool, message: []const u8) !Options {
    try status_cmd.writeDiagnostic(stdout, if (json) .json else .human, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    if (!json) {
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(stdout, usage);
    }
    try stdout.flush();
    std.process.exit(1);
}

fn gracePeriodMs(hours: u64) !i64 {
    const ms_per_hour: u64 = 60 * 60 * 1000;
    const total = try std.math.mul(u64, hours, ms_per_hour);
    return std.math.cast(i64, total) orelse error.Overflow;
}

fn parseUtcDateMidnight(text: []const u8) !i64 {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return error.InvalidDate;

    const year = try std.fmt.parseInt(i64, text[0..4], 10);
    const month = try std.fmt.parseInt(i64, text[5..7], 10);
    const day = try std.fmt.parseInt(i64, text[8..10], 10);

    if (month < 1 or month > 12) return error.InvalidDate;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidDate;

    const days = daysFromCivil(year, month, day);
    return try std.math.mul(i64, days, 24 * 60 * 60 * 1000);
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn daysFromCivil(year_input: i64, month_input: i64, day: i64) i64 {
    var year = year_input;
    const month = month_input;
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const mp: i64 = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parseUtcDateMidnight parses UTC dates" {
    try std.testing.expectEqual(@as(i64, 0), try parseUtcDateMidnight("1970-01-01"));
    try std.testing.expectEqual(@as(i64, 86_400_000), try parseUtcDateMidnight("1970-01-02"));
    try std.testing.expectError(error.InvalidDate, parseUtcDateMidnight("1970-13-01"));
}

const std = @import("std");

const gc_mod = @import("../store/gc.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const reindex_cmd = @import("reindex.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");
const store_mod = @import("../store/store.zig");
const date_util = @import("../util/date.zig");
const arg_parse = @import("arg_parse.zig");

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
            const value = iter.next();
            if (value == null) {
                arg_parse.invalidArg(stdout, if (options.json) .json else .human, usage, "--grace-hours requires an integer value.") catch {};
                std.process.exit(1);
            }
            options.grace_hours = std.fmt.parseUnsigned(u64, value.?, 10) catch {
                arg_parse.invalidArg(stdout, if (options.json) .json else .human, usage, "Invalid --grace-hours value.") catch {};
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--prune-before")) {
            const value = iter.next();
            if (value == null) {
                arg_parse.invalidArg(stdout, if (options.json) .json else .human, usage, "--prune-before requires a YYYY-MM-DD value.") catch {};
                std.process.exit(1);
            }
            options.prune_before_ms = date_util.parseUtcDateMidnight(value.?) catch {
                arg_parse.invalidArg(stdout, if (options.json) .json else .human, usage, "Invalid --prune-before date; use YYYY-MM-DD.") catch {};
                std.process.exit(1);
            };
            options.prune_before_raw = value.?;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            return error.HelpShown;
        } else {
            arg_parse.invalidArg(stdout, if (options.json) .json else .human, usage, "Unknown option.") catch {};
            std.process.exit(1);
        }
    }
    return options;
}

fn gracePeriodMs(hours: u64) !i64 {
    const ms_per_hour: u64 = 60 * 60 * 1000;
    const total = try std.math.mul(u64, hours, ms_per_hour);
    return std.math.cast(i64, total) orelse error.Overflow;
}

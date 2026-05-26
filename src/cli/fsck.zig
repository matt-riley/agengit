const std = @import("std");

const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const reindex_cmd = @import("reindex.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");
const store_mod = @import("../store/store.zig");
const integrity_mod = @import("../store/integrity.zig");

pub const usage = specs.fsck_usage;

const FsckOptions = struct {
    json: bool = false,
    reindex: bool = false,
};

const FsckStatsEnvelope = struct {
    object_files: usize,
    ref_files: usize,
    reachable_sessions: usize,
    reachable_steps: usize,
    warnings: usize,
    errors: usize,
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

    var repair_stats: ?integrity_mod.RepairStats = null;

    var report = try scanFromRepo(io, gpa, repo_dir);
    var report_active = true;
    defer if (report_active) report.deinit();

    if (options.reindex and !report.hasErrors()) {
        repair_stats = try repairIndex(io, gpa, repo_dir);
        const rescanned = scanFromRepo(io, gpa, repo_dir) catch |err| {
            report.deinit();
            report_active = false;
            return err;
        };
        report.deinit();
        report = rescanned;
    }

    if (options.json) {
        try writeJson(&stdout, &report, repair_stats);
    } else {
        try writeHuman(&stdout, &report, repair_stats);
    }
    try stdout.flush();
    if (report.hasErrors()) std.process.exit(1);
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !FsckOptions {
    var options: FsckOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else if (std.mem.eql(u8, arg, "--reindex")) {
            options.reindex = true;
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

fn scanFromRepo(io: std.Io, gpa: std.mem.Allocator, repo_dir: std.Io.Dir) !integrity_mod.ScanResult {
    var store_root = try repo_dir.openDir(io, ".agit", .{});
    defer store_root.close(io);

    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path_len = try store_root.realPath(io, &root_path_buf);
    return integrity_mod.scan(io, gpa, store_root, root_path_buf[0..root_path_len]);
}

fn repairIndex(io: std.Io, gpa: std.mem.Allocator, repo_dir: std.Io.Dir) !integrity_mod.RepairStats {
    const paths = [_][]const u8{ ".agit/index.db", ".agit/index.db-wal", ".agit/index.db-shm" };
    for (paths) |path| {
        repo_dir.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }

    var store = try store_mod.Store.openWithOptions(io, repo_dir, gpa, .{ .reconcile = false });
    defer store.deinit(io);
    try store.index.truncate();
    const stats = try reindex_cmd.reindex(io, gpa, &store);
    return .{
        .sessions = stats.sessions,
        .steps = stats.steps,
    };
}

fn writeHuman(
    stdout: *std.Io.File.Writer,
    report: *const integrity_mod.ScanResult,
    repair_stats: ?integrity_mod.RepairStats,
) !void {
    for (report.findings) |finding| {
        const sigil = switch (finding.severity) {
            .ok => "✓",
            .info => "-",
            .warn => "!",
            .@"error" => "✗",
        };
        try stdout.interface.print("  {s} {s}\n", .{ sigil, finding.message });
        if (finding.path) |path| try stdout.interface.print("      path: {s}\n", .{path});
        if (finding.hash) |hash| try stdout.interface.print("      hash: {s}\n", .{hash});
        if (finding.hint) |hint| try stdout.interface.print("      hint: {s}\n", .{hint});
    }

    if (repair_stats) |stats| {
        try stdout.interface.print(
            "  - reindexed query state: sessions={d} steps={d}\n",
            .{ stats.sessions, stats.steps },
        );
    }

    const summary = if (report.hasErrors())
        "corrupt"
    else if (report.hasWarnings())
        "warnings"
    else
        "ok";
    try stdout.interface.print(
        "fsck: {s} (objects={d} refs={d} reachable_sessions={d} reachable_steps={d})\n",
        .{
            summary,
            report.stats.object_files,
            report.stats.ref_files,
            report.stats.reachable_sessions,
            report.stats.reachable_steps,
        },
    );
}

fn writeJson(
    stdout: *std.Io.File.Writer,
    report: *const integrity_mod.ScanResult,
    repair_stats: ?integrity_mod.RepairStats,
) !void {
    var checks: std.ArrayList(output_mod.Check) = .empty;
    defer checks.deinit(std.heap.page_allocator);

    for (report.findings) |finding| {
        try checks.append(std.heap.page_allocator, .{
            .code = finding.code,
            .status = switch (finding.severity) {
                .ok => .ok,
                .info => .info,
                .warn => .warn,
                .@"error" => .@"error",
            },
            .message = finding.message,
            .hint = finding.hint,
            .path = finding.path,
            .hash = finding.hash,
        });
    }

    const check_slice = try checks.toOwnedSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(check_slice);

    try output_mod.writeEnvelope(stdout, usage.name, .{
        .healthy = !report.hasErrors(),
        .checks = check_slice,
        .stats = FsckStatsEnvelope{
            .object_files = report.stats.object_files,
            .ref_files = report.stats.ref_files,
            .reachable_sessions = report.stats.reachable_sessions,
            .reachable_steps = report.stats.reachable_steps,
            .warnings = report.stats.warnings,
            .errors = report.stats.errors,
        },
        .repair = if (repair_stats) |stats| stats else null,
    });
}

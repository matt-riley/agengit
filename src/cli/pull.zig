const std = @import("std");

const config_mod = @import("../store/config.zig");
const help_mod = @import("help.zig");
const integrity_mod = @import("../store/integrity.zig");
const output_mod = @import("output.zig");
const remote_mod = @import("../store/remote.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");
const store_mod = @import("../store/store.zig");

pub const usage = specs.pull_usage;

const Options = struct {
    format: output_mod.Format = .human,
    remote_name: ?[]const u8 = null,
};

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    var store = try status_cmd.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    var loaded = config_mod.loadFromStore(io, store.root, gpa) catch |err| {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_config",
            .message = "Failed to load .agit/config.json.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer loaded.deinit();

    const remote = config_mod.selectRemote(loaded.value, options.remote_name) catch |err| {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, remoteSelectionDiagnostic(err));
        try stdout.flush();
        std.process.exit(1);
    };

    try ensureFsckHealthy(io, &stdout, options.format, &store);

    var result = remote_mod.pull(io, gpa, environ, &store, remote) catch |err| {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "pull_failed",
            .message = "Failed to pull store data from the configured remote.",
            .hint = @errorName(err),
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer result.deinit(gpa);

    if (result.first_conflict) |conflict| {
        const hint = try std.fmt.allocPrint(gpa, "{s} local={s} remote={s}", .{
            conflict.path,
            conflict.local_hash[0..],
            conflict.remote_hash[0..],
        });
        defer gpa.free(hint);
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "remote_conflict",
            .message = "Local ref diverged from the pulled remote ref.",
            .hint = hint,
            .path = conflict.path,
        });
        try stdout.flush();
        std.process.exit(1);
    }

    const reconcile = try store.reconcile(io, gpa, .repair);
    switch (options.format) {
        .human => try stdout.interface.print(
            "pull: downloaded_objects={d} skipped_objects={d} created_refs={d} updated_refs={d} unchanged_refs={d} encrypted={s} reconciled={d}\n",
            .{
                result.downloaded_objects,
                result.skipped_objects,
                result.created_refs,
                result.updated_refs,
                result.unchanged_refs,
                if (result.encrypted) "yes" else "no",
                reconcile.repaired,
            },
        ),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .downloaded_objects = result.downloaded_objects,
            .skipped_objects = result.skipped_objects,
            .created_refs = result.created_refs,
            .updated_refs = result.updated_refs,
            .unchanged_refs = result.unchanged_refs,
            .encrypted = result.encrypted,
            .reconcile = reconcile,
        }),
    }
    try stdout.flush();
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !Options {
    var options: Options = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--remote")) {
            options.remote_name = iter.next() orelse return invalidArgument(stdout, options.format, "--remote requires a name.");
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            return invalidArgument(stdout, options.format, "Unknown option.");
        }
    }
    return options;
}

fn invalidArgument(stdout: *std.Io.File.Writer, format: output_mod.Format, message: []const u8) !Options {
    try status_cmd.writeDiagnostic(stdout, format, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    if (format == .human) {
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(stdout, usage);
    }
    try stdout.flush();
    std.process.exit(1);
}

fn remoteSelectionDiagnostic(err: anyerror) output_mod.Diagnostic {
    return switch (err) {
        error.RemoteNotConfigured => .{
            .code = "remote_not_configured",
            .message = "No remotes are configured in .agit/config.json.",
            .path = ".agit/config.json",
        },
        error.RemoteSelectionRequired => .{
            .code = "remote_selection_required",
            .message = "Multiple remotes are configured; choose one with --remote.",
            .path = ".agit/config.json",
        },
        error.RemoteNotFound => .{
            .code = "remote_not_found",
            .message = "The requested remote does not exist.",
            .path = ".agit/config.json",
        },
        error.DuplicateRemoteName => .{
            .code = "remote_duplicate_name",
            .message = "The configured remotes contain duplicate names.",
            .path = ".agit/config.json",
        },
        else => .{
            .code = "remote_select_failed",
            .message = "Failed to resolve the configured remote.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        },
    };
}

fn ensureFsckHealthy(
    io: std.Io,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    store: *store_mod.Store,
) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try store.root.realPath(io, &path_buf);
    var report = try integrity_mod.scan(io, std.heap.page_allocator, store.root, path_buf[0..path_len]);
    defer report.deinit();
    if (!report.hasErrors()) return;

    try status_cmd.writeDiagnostic(stdout, format, usage.name, .{
        .code = "fsck_failed",
        .message = "Refusing to pull into a corrupt local store.",
        .hint = "Run `agit fsck` to inspect integrity findings before retrying.",
        .path = ".agit",
    });
    try stdout.flush();
    std.process.exit(1);
}

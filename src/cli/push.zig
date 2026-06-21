const std = @import("std");

const config_mod = @import("../store/config.zig");
const help_mod = @import("help.zig");
const integrity_mod = @import("../store/integrity.zig");
const output_mod = @import("output.zig");
const privacy_scan_mod = @import("../privacy/scan.zig");
const remote_mod = @import("../store/remote.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");
const arg_parse = @import("arg_parse.zig");

pub const usage = specs.push_usage;

const Options = struct {
    format: output_mod.Format = .human,
    remote_name: ?[]const u8 = null,
    allow_sensitive: bool = false,
};

const min_encryption_secret_bytes: usize = 16;

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

    try ensureFsckHealthy(io, gpa, &stdout, options.format, &store);

    var privacy_report = try privacy_scan_mod.scanStore(io, gpa, &store, loaded.value.privacy);
    defer privacy_report.deinit();
    const encrypted = if (remote.encryption_secret_env) |name| hasUsableEncryptionSecret(environ, name) else false;
    if (!options.allow_sensitive and !encrypted and !privacy_report.clean()) {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "privacy_blocked",
            .message = "Refusing to upload sensitive plaintext store data.",
            .hint = "Configure encryption_secret_env for the remote or rerun with --allow-sensitive.",
        });
        try stdout.flush();
        std.process.exit(1);
    }

    var result = remote_mod.push(io, gpa, environ, &store, remote) catch |err| {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "push_failed",
            .message = "Failed to push store data to the configured remote.",
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
            .message = "Remote ref is not an ancestor of the local ref; pull first.",
            .hint = hint,
            .path = conflict.path,
        });
        try stdout.flush();
        std.process.exit(1);
    }

    switch (options.format) {
        .human => try stdout.interface.print(
            "push: uploaded_objects={d} skipped_objects={d} uploaded_refs={d} skipped_refs={d} encrypted={s}\n",
            .{
                result.uploaded_objects,
                result.skipped_objects,
                result.uploaded_refs,
                result.skipped_refs,
                if (result.encrypted) "yes" else "no",
            },
        ),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .uploaded_objects = result.uploaded_objects,
            .skipped_objects = result.skipped_objects,
            .uploaded_refs = result.uploaded_refs,
            .skipped_refs = result.skipped_refs,
            .encrypted = result.encrypted,
            .privacy_findings = privacy_report.findings.len,
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
            const name = iter.next();
            if (name == null) {
                arg_parse.invalidArg(stdout, options.format, usage, "--remote requires a name.") catch {};
                std.process.exit(1);
            }
            options.remote_name = name.?;
        } else if (std.mem.eql(u8, arg, "--allow-sensitive")) {
            options.allow_sensitive = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            arg_parse.invalidArg(stdout, options.format, usage, "Unknown option.") catch {};
            std.process.exit(1);
        }
    }
    return options;
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
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    store: *store_mod.Store,
) !void {
    _ = gpa;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try store.root.realPath(io, &path_buf);
    var report = try integrity_mod.scan(io, std.heap.page_allocator, store.root, path_buf[0..path_len]);
    defer report.deinit();
    if (!report.hasErrors()) return;

    try status_cmd.writeDiagnostic(stdout, format, usage.name, .{
        .code = "fsck_failed",
        .message = "Refusing to push from a corrupt local store.",
        .hint = "Run `agit fsck` to inspect integrity findings before retrying.",
        .path = ".agit",
    });
    try stdout.flush();
    std.process.exit(1);
}

fn hasUsableEncryptionSecret(environ: std.process.Environ, name: []const u8) bool {
    const value = environ.getPosix(name) orelse return false;
    return std.mem.trim(u8, value, " \t\r\n").len >= min_encryption_secret_bytes;
}

const store_mod = @import("../store/store.zig");

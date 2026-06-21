const std = @import("std");

const bundle_mod = @import("../store/bundle.zig");
const config_mod = @import("../store/config.zig");
const date_util = @import("../util/date.zig");
const help_mod = @import("help.zig");
const integrity_mod = @import("../store/integrity.zig");
const output_mod = @import("output.zig");
const privacy_scan_mod = @import("../privacy/scan.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");
const arg_parse = @import("arg_parse.zig");
const store_mod = @import("../store/store.zig");

pub const usage = specs.export_usage;

const Options = struct {
    format: output_mod.Format = .human,
    path: ?[]const u8 = null,
    filters: bundle_mod.ExportFilters = .{},
    allow_sensitive: bool = false,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown, error.InvalidArgument => return,
        else => return err,
    };

    if (options.filters.since_ms != null and options.filters.until_ms_exclusive != null and options.filters.since_ms.? >= options.filters.until_ms_exclusive.?) {
        try arg_parse.invalidArg(&stdout, options.format, usage, "--since must be earlier than --until (the --until date is exclusive).");
        return;
    }

    const bundle_path = options.path orelse {
        try arg_parse.invalidArg(&stdout, options.format, usage, "export requires a target directory path.");
        return;
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

    const selected_refs = try bundle_mod.selectRefs(io, gpa, &store, options.filters);
    defer bundle_mod.freeManifestRefs(gpa, selected_refs);
    if (selected_refs.len == 0) {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "no_matching_sessions",
            .message = "No recorded sessions match the requested export filters.",
        });
        try stdout.flush();
        std.process.exit(1);
    }

    try ensureFsckHealthy(io, &stdout, options.format, &store);

    const selected_sessions = try buildSessionRows(gpa, selected_refs);
    defer store_mod.freeSessionRows(gpa, selected_sessions);

    var privacy_report = try privacy_scan_mod.scanSessions(io, gpa, &store, loaded.value.privacy, selected_sessions);
    defer privacy_report.deinit();
    if (!options.allow_sensitive and !privacy_report.clean()) {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "privacy_blocked",
            .message = "Refusing to export sensitive plaintext bundle contents.",
            .hint = "Rerun with --allow-sensitive to include a privacy report without secret values.",
        });
        try stdout.flush();
        std.process.exit(1);
    }

    const repository_hint = try repositoryHintAlloc(io, gpa, &store);
    defer if (repository_hint) |hint| gpa.free(hint);

    const privacy_report_json = if (!privacy_report.clean() and options.allow_sensitive)
        try stringifyPrivacyReport(gpa, &privacy_report)
    else
        null;
    defer if (privacy_report_json) |json| gpa.free(json);

    const result = bundle_mod.exportBundle(io, gpa, &store, .{
        .path = bundle_path,
        .producer_version = @import("../version.zig").value,
        .repository_hint = repository_hint,
        .filters = options.filters,
        .privacy_findings = privacy_report.findings.len,
        .privacy_report_json = privacy_report_json,
    }) catch |err| {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "export_failed",
            .message = "Failed to write the portable bundle.",
            .hint = @errorName(err),
            .path = bundle_path,
        });
        try stdout.flush();
        std.process.exit(1);
    };

    switch (options.format) {
        .human => try stdout.interface.print(
            "export: path={s} bundle={s} exported_objects={d} exported_refs={d} privacy_findings={d}\n",
            .{
                bundle_path,
                result.bundle_id[0..12],
                result.exported_objects,
                result.exported_refs,
                privacy_report.findings.len,
            },
        ),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .path = bundle_path,
            .bundle_id = result.bundle_id[0..],
            .exported_objects = result.exported_objects,
            .exported_refs = result.exported_refs,
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
        } else if (std.mem.eql(u8, arg, "--origin")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--origin requires a value.");
                return error.InvalidArgument;
            };
            options.filters.origin = value;
        } else if (std.mem.eql(u8, arg, "--session")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--session requires an origin/session-id value.");
                return error.InvalidArgument;
            };
            options.filters.session = parseSessionSpec(value) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --session value; use origin/session-id.");
                return error.InvalidArgument;
            };
            options.filters.session_text = value;
        } else if (std.mem.eql(u8, arg, "--since")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--since requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.filters.since_ms = date_util.parseUtcDateMidnight(value) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --since date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.filters.since_text = value;
        } else if (std.mem.eql(u8, arg, "--until")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--until requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.filters.until_ms_exclusive = date_util.parseUtcDateEndExclusive(value) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --until date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.filters.until_text = value;
        } else if (std.mem.eql(u8, arg, "--allow-sensitive")) {
            options.allow_sensitive = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try arg_parse.invalidArg(stdout, options.format, usage, "Unknown option.");
            return error.InvalidArgument;
        } else if (options.path == null) {
            options.path = arg;
        } else {
            try arg_parse.invalidArg(stdout, options.format, usage, "export accepts only one target directory path.");
            return error.InvalidArgument;
        }
    }
    return options;
}

fn parseSessionSpec(raw: []const u8) !bundle_mod.SessionFilter {
    const sep = std.mem.indexOfScalar(u8, raw, '/') orelse return error.InvalidSession;
    if (sep == 0 or sep + 1 >= raw.len) return error.InvalidSession;
    return .{
        .origin = raw[0..sep],
        .session_id = raw[sep + 1 ..],
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
        .message = "Refusing to export from a corrupt local store.",
        .hint = "Run `agit fsck` to inspect integrity findings before retrying.",
        .path = ".agit",
    });
    try stdout.flush();
    std.process.exit(1);
}

fn buildSessionRows(gpa: std.mem.Allocator, refs: []const bundle_mod.ManifestRef) ![]const store_mod.SessionRow {
    const rows = try gpa.alloc(store_mod.SessionRow, refs.len);
    var initialized: usize = 0;
    errdefer {
        for (rows[0..initialized]) |row| store_mod.freeSessionRow(gpa, row);
        gpa.free(rows);
    }

    for (refs, 0..) |ref_entry, i| {
        rows[i] = .{
            .origin = try gpa.dupe(u8, ref_entry.origin),
            .session_id = try gpa.dupe(u8, ref_entry.session_id),
            .head_hash = try gpa.dupe(u8, ref_entry.head_hash),
            .updated_at = 0,
        };
        initialized = i + 1;
    }
    return rows;
}

fn repositoryHintAlloc(io: std.Io, gpa: std.mem.Allocator, store: *store_mod.Store) !?[]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try store.root.realPath(io, &path_buf);
    const agit_path = path_buf[0..path_len];
    const repo_path = std.fs.path.dirname(agit_path) orelse return null;
    const base = std.fs.path.basename(repo_path);
    if (base.len == 0) return null;
    return try gpa.dupe(u8, base);
}

fn stringifyPrivacyReport(gpa: std.mem.Allocator, report: *const privacy_scan_mod.Result) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(gpa);
    errdefer writer.deinit();
    try std.json.Stringify.value(.{
        .stats = report.stats,
        .findings = report.findings,
    }, .{}, &writer.writer);
    var list = writer.toArrayList();
    return list.toOwnedSlice(gpa);
}

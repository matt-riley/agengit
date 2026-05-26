const std = @import("std");

const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const privacy_scan_mod = @import("../privacy/scan.zig");
const specs = @import("specs.zig");
const status = @import("status.zig");
const config_mod = @import("../store/config.zig");

pub const usage = specs.privacy_usage;

const PrivacyOptions = struct {
    format: output_mod.Format = .human,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const subcommand = iter.next() orelse {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        std.process.exit(1);
    };
    if (std.mem.eql(u8, subcommand, "-h") or std.mem.eql(u8, subcommand, "--help")) {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    }
    if (!std.mem.eql(u8, subcommand, "scan")) {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
            .code = "invalid_subcommand",
            .message = "Unknown privacy subcommand.",
            .hint = subcommand,
        });
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        std.process.exit(1);
    }

    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    var loaded = config_mod.loadFromStore(io, store.root, gpa) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_config",
            .message = "Failed to load .agit/config.json.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer loaded.deinit();

    var report = try privacy_scan_mod.scanStore(io, gpa, &store, loaded.value.privacy);
    defer report.deinit();

    switch (options.format) {
        .human => try writeHuman(&stdout, &report),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .clean = report.clean(),
            .stats = report.stats,
            .findings = report.findings,
        }),
    }
    try stdout.flush();
    if (!report.clean()) std.process.exit(1);
}

fn writeHuman(stdout: *std.Io.File.Writer, report: *const privacy_scan_mod.Result) !void {
    if (report.clean()) {
        try stdout.interface.print(
            "privacy scan: clean (sessions={d} steps={d} trees={d} blobs={d})\n",
            .{ report.stats.sessions, report.stats.steps, report.stats.trees, report.stats.blobs },
        );
        return;
    }

    try stdout.interface.print(
        "privacy scan: {d} finding(s) across {d} session(s)\n",
        .{ report.findings.len, report.stats.sessions },
    );
    for (report.findings) |finding| {
        try stdout.interface.print("  - [{s}] {s} in {s}", .{
            @tagName(finding.severity),
            finding.rule,
            finding.source,
        });
        if (finding.origin != null and finding.session_id != null and finding.turn_id != null) {
            try stdout.interface.print(" ({s}/{s} turn {s})", .{
                finding.origin.?,
                finding.session_id.?,
                finding.turn_id.?,
            });
        }
        if (finding.path) |path| {
            try stdout.interface.print(" path={s}", .{path});
        }
        try stdout.interface.writeAll("\n");
    }
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !PrivacyOptions {
    var options: PrivacyOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            try status.writeDiagnostic(stdout, options.format, usage.name, .{
                .code = "invalid_argument",
                .message = "Unexpected argument.",
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

const std = @import("std");
const store_mod = @import("../store/store.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");

pub const usage = help_mod.UsageSpec{
    .name = "status",
    .synopsis = "[OPTIONS]",
    .description = "Show current repository state and agit store statistics.",
    .options = &.{
        .{ .long = "json", .description = "Render the status as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show repository status", .command = "" },
    },
};

const StatusOptions = struct {
    format: output_mod.Format = .human,
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

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    var store = try openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    const n_sessions = try store.index.countSessions();
    const n_steps = try store.index.countSteps();

    switch (options.format) {
        .human => {
            try stdout.interface.print("Sessions: {d}\n", .{n_sessions});
            try stdout.interface.print("Steps:    {d}\n", .{n_steps});
            try stdout.flush();
        },
        .json => {
            try output_mod.writeEnvelope(&stdout, usage.name, .{
                .sessions = n_sessions,
                .steps = n_steps,
            });
            try stdout.flush();
        },
    }
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

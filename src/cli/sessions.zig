const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");

pub const usage = help_mod.UsageSpec{
    .name = "sessions",
    .synopsis = "[OPTIONS]",
    .description = "List recorded agent sessions from the index.",
    .options = &.{
        .{ .long = "json", .description = "Render the session list as structured JSON." },
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "list all sessions", .command = "" },
    },
};

const SessionsOptions = struct {
    format: output_mod.Format = .human,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    const sessions = try store.index.listSessions(gpa);
    defer store_mod.freeSessionRows(gpa, sessions);

    switch (options.format) {
        .human => try writeHuman(&stdout, sessions),
        .json => try writeJson(&stdout, sessions),
    }
    try stdout.flush();
}

fn writeHuman(stdout: *std.Io.File.Writer, sessions: []const store_mod.SessionRow) !void {
    if (sessions.len == 0) {
        try stdout.interface.writeAll("No sessions recorded yet. Run `agit init` and record some activity.\n");
        return;
    }

    try stdout.interface.writeAll("ORIGIN                         SESSION                  HEAD      UPDATED\n");
    try stdout.interface.writeAll("────────────────────────────── ──────────────────────── ──────── ───────────────────\n");

    var ts_buf: [32]u8 = undefined;
    for (sessions) |s| {
        const head = if (s.head_hash) |h| h[0..@min(8, h.len)] else "────────";
        const updated = status.formatTimestamp(s.updated_at * 1000, &ts_buf);
        try stdout.interface.print("{s:<30} {s:<24} {s:<8} {s}\n", .{
            s.origin[0..@min(30, s.origin.len)],
            s.session_id[0..@min(24, s.session_id.len)],
            head,
            updated,
        });
    }
}

fn writeJson(stdout: *std.Io.File.Writer, sessions: []const store_mod.SessionRow) !void {
    try output_mod.writeEnvelope(stdout, usage.name, .{
        .sessions = sessions,
    });
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !SessionsOptions {
    var options: SessionsOptions = .{};
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

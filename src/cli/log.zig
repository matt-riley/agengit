const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const arg_parse = @import("arg_parse.zig");

pub const usage = specs.log_usage;

const LogOptions = struct {
    format: output_mod.Format = .human,
    session_arg: ?[:0]const u8 = null,
};

const SessionTarget = struct {
    origin: []const u8,
    session_id: []const u8,
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

    const resolved = try resolveSessionArg(gpa, &store, options.session_arg, &stdout, options.format);
    defer {
        gpa.free(resolved.origin);
        gpa.free(resolved.session_id);
    }

    const steps = try store.index.listSteps(gpa, resolved.origin, resolved.session_id);
    defer store_mod.freeStepRows(gpa, steps);

    switch (options.format) {
        .human => try writeHuman(&stdout, resolved, steps),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .origin = resolved.origin,
            .session_id = resolved.session_id,
            .steps = steps,
        }),
    }
    try stdout.flush();
}

fn writeHuman(stdout: *std.Io.File.Writer, resolved: SessionTarget, steps: []const store_mod.StepRow) !void {
    if (steps.len == 0) {
        try stdout.interface.print("No steps recorded for {s}/{s}\n", .{
            resolved.origin,
            resolved.session_id,
        });
        return;
    }

    try stdout.interface.print("session {s}/{s}\n\n", .{ resolved.origin, resolved.session_id });

    var ts_buf: [32]u8 = undefined;
    var i = steps.len;
    while (i > 0) {
        i -= 1;
        const step = steps[i];
        const ts = status.formatTimestamp(step.timestamp, &ts_buf);
        try stdout.interface.print("step {s}  turn {s}  {s}\n", .{
            step.hash[0..@min(16, step.hash.len)],
            step.turn_id,
            ts,
        });
        if (step.model) |model| {
            try stdout.interface.print("  model {s}\n", .{model});
        }
    }
}

fn resolveSessionArg(
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    arg: ?[:0]const u8,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
) !SessionTarget {
    if (arg) |value| {
        if (std.mem.indexOfScalar(u8, value, '/')) |sep| {
            return .{
                .origin = try gpa.dupe(u8, value[0..sep]),
                .session_id = try gpa.dupe(u8, value[sep + 1 ..]),
            };
        }

        const row = try store.index.db.row(
            "select origin, session_id from sessions where session_id=? order by updated_at desc limit 1",
            .{value},
        ) orelse {
            try status.writeDiagnostic(stdout, format, usage.name, .{
                .code = "session_not_found",
                .message = "Session not found.",
                .hint = "Pass <origin>/<session-id> to disambiguate or run `agit sessions`.",
                .path = value,
            });
            try stdout.flush();
            std.process.exit(1);
        };
        defer row.deinit();
        return .{
            .origin = try gpa.dupe(u8, row.get([]const u8, 0)),
            .session_id = try gpa.dupe(u8, row.get([]const u8, 1)),
        };
    }

    const sess = try store.index.mostRecentSession(gpa) orelse {
        try status.writeDiagnostic(stdout, format, usage.name, .{
            .code = "session_not_found",
            .message = "No sessions recorded yet.",
            .hint = "Record some activity first or pass an explicit session id.",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    if (sess.head_hash) |hh| gpa.free(hh);
    return .{ .origin = sess.origin, .session_id = sess.session_id };
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !LogOptions {
    var options: LogOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (options.session_arg == null) {
            options.session_arg = arg;
        } else {
            arg_parse.invalidArg(stdout, options.format, usage, "Unexpected argument.") catch {};
            std.process.exit(1);
        }
    }
    return options;
}

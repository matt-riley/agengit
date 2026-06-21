const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const arg_parse = @import("arg_parse.zig");
const session_arg = @import("session_arg.zig");

pub const usage = specs.log_usage;

const LogOptions = struct {
    format: output_mod.Format = .human,
    session_arg: ?[:0]const u8 = null,
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

    const resolved = try session_arg.resolveExisting(gpa, &store, &stdout, options.format, usage.name, options.session_arg);
    defer resolved.deinit(gpa);

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

fn writeHuman(stdout: *std.Io.File.Writer, resolved: session_arg.Target, steps: []const store_mod.StepRow) !void {
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

const std = @import("std");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");

pub const usage = specs.show_usage;

const ShowOptions = struct {
    format: output_mod.Format = .human,
    hash_prefix: ?[:0]const u8 = null,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    const prefix = options.hash_prefix orelse {
        if (options.format == .json) {
            try status.writeDiagnostic(&stdout, .json, usage.name, .{
                .code = "missing_hash",
                .message = "A hash prefix is required.",
            });
        } else {
            try help_mod.renderUsage(&stdout, usage);
        }
        try stdout.flush();
        std.process.exit(1);
    };

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    const resolution = store.resolvePrefix(io, gpa, prefix) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "object_lookup_failed",
            .message = "Failed to resolve object prefix.",
            .hint = @errorName(err),
            .hash = prefix,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    const h = switch (resolution) {
        .not_found => {
            try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                .code = "object_not_found",
                .message = "Object not found.",
                .hint = "Use a longer or different hash prefix.",
                .hash = prefix,
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .ambiguous => |matches| {
            var candidate_hex: [2][64]u8 = .{ matches[0].toHex(), matches[1].toHex() };
            if (std.mem.lessThan(u8, candidate_hex[1][0..], candidate_hex[0][0..])) {
                std.mem.swap([64]u8, &candidate_hex[0], &candidate_hex[1]);
            }
            const candidates = [_][]const u8{ candidate_hex[0][0..], candidate_hex[1][0..] };
            try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                .code = "ambiguous_hash_prefix",
                .message = "Hash prefix is ambiguous.",
                .hint = "Use a longer hash prefix.",
                .hash = prefix,
                .candidates = candidates[0..],
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .unique => |resolved| resolved,
    };
    const hex = h.toHex();

    var parsed = store.readStep(io, gpa, h) catch |err| {
        const diagnostic: output_mod.Diagnostic = switch (err) {
            error.UnknownField,
            error.InvalidCharacter,
            error.UnexpectedToken,
            error.InvalidNumber,
            error.Overflow,
            error.InvalidEnumTag,
            error.DuplicateField,
            error.MissingField,
            error.LengthMismatch,
            error.SyntaxError,
            => .{
                .code = "invalid_step_object",
                .message = "Object is not a step.",
                .hash = hex[0..],
            },
            else => .{
                .code = "object_read_failed",
                .message = "Failed to read step object.",
                .hint = @errorName(err),
                .hash = hex[0..],
            },
        };
        try status.writeDiagnostic(&stdout, options.format, usage.name, diagnostic);
        try stdout.flush();
        std.process.exit(1);
    };
    defer parsed.deinit();

    switch (options.format) {
        .human => try writeHuman(&stdout, hex[0..], parsed.value),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .hash = hex[0..],
            .step = parsed.value,
        }),
    }
    try stdout.flush();
}

fn writeHuman(stdout: *std.Io.File.Writer, hex: []const u8, step: anytype) !void {
    var ts_buf: [32]u8 = undefined;
    const ts = status.formatTimestamp(step.timestamp, &ts_buf);

    try stdout.interface.print("step      {s}\n", .{hex});
    try stdout.interface.print("origin    {s}\n", .{step.origin});
    try stdout.interface.print("session   {s}\n", .{step.session_id});
    try stdout.interface.print("turn      {s}\n", .{step.turn_id});
    try stdout.interface.print("parent    {s}\n", .{step.parent orelse "(none)"});
    try stdout.interface.print("tree      {s}\n", .{step.tree});
    try stdout.interface.print("timestamp {s}\n", .{ts});

    if (step.messages.len > 0) {
        try stdout.interface.writeAll("\nmessages:\n");
        for (step.messages, 0..) |msg, i| {
            const preview_len = @min(80, msg.content.len);
            const preview = msg.content[0..preview_len];
            const ellipsis: []const u8 = if (msg.content.len > 80) "…" else "";
            try stdout.interface.print("  [{d}] {s}: {s}{s}\n", .{ i, msg.role, preview, ellipsis });
        }
    }

    if (step.tool_calls.len > 0) {
        try stdout.interface.writeAll("\ntool_calls:\n");
        for (step.tool_calls, 0..) |tc, i| {
            try stdout.interface.print("  [{d}] {s}\n", .{ i, tc.tool_name });
        }
    }
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !ShowOptions {
    var options: ShowOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (options.hash_prefix == null) {
            options.hash_prefix = arg;
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

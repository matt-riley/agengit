const std = @import("std");
const store_mod = @import("../store/store.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");

pub const usage = help_mod.UsageSpec{
    .name = "show",
    .synopsis = "[OPTIONS] <HASH>",
    .description = "Show details of a recorded step object by its BLAKE3 hash.",
    .options = &.{
        .{ .flag = "-h, --help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "show details of a step", .command = "abc123def" },
    },
};

// Phase 6 implementation: show details of a named step object.
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    // Parse --help and hash prefix
    var help_requested = false;
    var hash_prefix: ?[:0]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help_requested = true;
            break;
        } else if (hash_prefix == null) {
            hash_prefix = arg;
        }
    }

    if (help_requested) {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    }

    const prefix = hash_prefix orelse {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    };

    var store = (try status.openStoreOrDie(io, gpa, &stdout)) orelse return;
    defer store.deinit(io);

    const h = store.resolvePrefix(io, gpa, prefix) catch |err| {
        switch (err) {
            error.ObjectNotFound => try stdout.interface.print(
                "error: object '{s}' not found\n",
                .{prefix},
            ),
            error.AmbiguousPrefix => try stdout.interface.print(
                "error: ambiguous prefix '{s}' — be more specific\n",
                .{prefix},
            ),
            else => try stdout.interface.print("error: {s}\n", .{@errorName(err)}),
        }
        try stdout.flush();
        return;
    };
    const hex = h.toHex();

    var parsed = store.readStep(io, gpa, h) catch |err| {
        switch (err) {
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
            => try stdout.interface.print(
                "error: {s} is not a step object\n",
                .{hex[0..16]},
            ),
            else => try stdout.interface.print("error: {s}\n", .{@errorName(err)}),
        }
        try stdout.flush();
        return;
    };
    defer parsed.deinit();

    const step = parsed.value;
    var ts_buf: [32]u8 = undefined;
    const ts = status.formatTimestamp(step.timestamp, &ts_buf);

    try stdout.interface.print("step      {s}\n", .{&hex});
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

    try stdout.flush();
}

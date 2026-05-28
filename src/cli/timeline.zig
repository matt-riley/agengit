const std = @import("std");
const config_mod = @import("../store/config.zig");
const date_util = @import("../util/date.zig");
const redact_mod = @import("../privacy/redact.zig");
const store_mod = @import("../store/store.zig");
const help_mod = @import("help.zig");
const specs = @import("specs.zig");
const status = @import("status.zig");

pub const usage = specs.timeline_usage;

const default_limit: usize = 20;
const preview_limit: usize = 96;

const RedactionMode = enum {
    auto,
    redacted,
    full,
};

const TimelineOptions = struct {
    origin: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,
    since_raw: ?[:0]const u8 = null,
    until_raw: ?[:0]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    limit: usize = default_limit,
    redaction_mode: RedactionMode = .auto,
};

const SessionFilter = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        error.InvalidArgument => return,
        else => return err,
    };

    if (options.since_ms != null and options.until_ms_exclusive != null and options.since_ms.? >= options.until_ms_exclusive.?) {
        try invalidArgument(&stdout, "--since must be earlier than --until (the --until date is exclusive).");
        return;
    }

    const session_filter = try resolveSessionFilter(&stdout, options);

    var store = try status.openStoreOrExit(io, gpa, &stdout, .human, usage.name);
    defer store.deinit(io);

    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
            .code = "invalid_config",
            .message = "Failed to load .agit/config.json.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer loaded_config.deinit();
    const use_redaction = shouldUseRedaction(options.redaction_mode, loaded_config.value.privacy.display.redacted_by_default);

    const rows = store.index.listRecentSteps(gpa, .{
        .origin = session_filter.origin,
        .session_id = session_filter.session_id,
        .since_ms = options.since_ms,
        .until_ms_exclusive = options.until_ms_exclusive,
        .limit = options.limit,
    }) catch |err| {
        try status.writeDiagnostic(&stdout, .human, usage.name, .{
            .code = "timeline_query_failed",
            .message = "Failed to query recent steps.",
            .hint = @errorName(err),
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer store_mod.freeTimelineRows(gpa, rows);

    try writeHuman(
        io,
        gpa,
        &stdout,
        &store,
        rows,
        use_redaction,
        loaded_config.value.privacy.custom_literals,
    );
    try stdout.flush();
}

fn writeHuman(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    rows: []const store_mod.TimelineRow,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !void {
    if (rows.len == 0) {
        try stdout.interface.writeAll("No recorded steps match the requested filters.\n");
        return;
    }

    var ts_buf: [32]u8 = undefined;
    for (rows, 0..) |row, i| {
        const hash = store_mod.Hash.fromHex(row.hash) catch {
            try status.writeDiagnostic(stdout, .human, usage.name, .{
                .code = "invalid_step_hash",
                .message = "Timeline row contains an invalid step hash.",
                .hash = row.hash,
            });
            try stdout.flush();
            std.process.exit(1);
        };
        var parsed = store.readStep(io, gpa, hash) catch |err| {
            try status.writeDiagnostic(stdout, .human, usage.name, .{
                .code = "step_read_failed",
                .message = "Failed to read a step referenced by the timeline.",
                .hint = @errorName(err),
                .hash = row.hash,
            });
            try stdout.flush();
            std.process.exit(1);
        };
        defer parsed.deinit();

        const preview_source = choosePreview(parsed.value);
        const preview_text = if (use_redaction) try redact_mod.redactAlloc(gpa, preview_source, .{
            .custom_literals = custom_literals,
        }) else preview_source;
        defer if (use_redaction) gpa.free(preview_text);

        const preview = try normalizePreviewAlloc(gpa, preview_text, preview_limit);
        defer gpa.free(preview);

        if (i > 0) try stdout.interface.writeAll("\n");
        try stdout.interface.print("{s}  {s}/{s}  turn {s}  step {s}\n", .{
            status.formatTimestamp(row.timestamp, &ts_buf),
            row.origin,
            row.session_id,
            row.turn_id,
            row.hash[0..@min(12, row.hash.len)],
        });
        try stdout.interface.print("  {s}\n", .{preview});
    }
}

fn choosePreview(step: store_mod.Step) []const u8 {
    for (step.messages) |message| {
        if (std.mem.eql(u8, message.role, "user") and message.content.len > 0) return message.content;
    }
    for (step.messages) |message| {
        if (std.mem.eql(u8, message.role, "assistant") and message.content.len > 0) return message.content;
    }
    for (step.tool_calls) |tool_call| {
        if (tool_call.result) |result| {
            if (result.len > 0) return result;
        }
        if (tool_call.args.len > 0) return tool_call.args;
        if (tool_call.tool_name.len > 0) return tool_call.tool_name;
    }
    return "(no preview)";
}

fn normalizePreviewAlloc(gpa: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var previous_was_space = false;
    var i: usize = 0;
    while (i < text.len and out.items.len < limit) : (i += 1) {
        const ch = text[i];
        const normalized = switch (ch) {
            '\r', '\n', '\t' => ' ',
            else => ch,
        };

        if (normalized == ' ') {
            if (previous_was_space or out.items.len == 0) continue;
            previous_was_space = true;
        } else {
            previous_was_space = false;
        }
        try out.append(gpa, normalized);
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop().?;
    }

    if (i < text.len and out.items.len > 0) {
        if (out.items.len == limit) _ = out.pop().?;
        try out.appendSlice(gpa, "…");
    }

    if (out.items.len == 0) try out.appendSlice(gpa, "(empty preview)");
    return out.toOwnedSlice(gpa);
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !TimelineOptions {
    var options: TimelineOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--origin")) {
            options.origin = iter.next() orelse {
                try invalidArgument(stdout, "--origin requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--session")) {
            options.session = iter.next() orelse {
                try invalidArgument(stdout, "--session requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--since")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, "--since requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.since_ms = date_util.parseUtcDateMidnight(value) catch {
                try invalidArgument(stdout, "Invalid --since date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.since_raw = value;
        } else if (std.mem.eql(u8, arg, "--until")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, "--until requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.until_ms_exclusive = date_util.parseUtcDateEndExclusive(value) catch {
                try invalidArgument(stdout, "Invalid --until date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.until_raw = value;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, "--limit requires an integer value.");
                return error.InvalidArgument;
            };
            options.limit = std.fmt.parseUnsigned(usize, value, 10) catch {
                try invalidArgument(stdout, "Invalid --limit value.");
                return error.InvalidArgument;
            };
            if (options.limit == 0) {
                try invalidArgument(stdout, "--limit must be greater than zero.");
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--redacted")) {
            options.redaction_mode = .redacted;
        } else if (std.mem.eql(u8, arg, "--full")) {
            options.redaction_mode = .full;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            try invalidArgument(stdout, "Unexpected argument.");
            return error.InvalidArgument;
        }
    }
    return options;
}

fn resolveSessionFilter(stdout: *std.Io.File.Writer, options: TimelineOptions) !SessionFilter {
    var filter: SessionFilter = .{ .origin = options.origin };
    if (options.session) |session| {
        if (std.mem.indexOfScalar(u8, session, '/')) |sep| {
            const qualified_origin = session[0..sep];
            if (filter.origin) |origin| {
                if (!std.mem.eql(u8, origin, qualified_origin)) {
                    try invalidArgument(stdout, "--origin does not match the origin prefix embedded in --session.");
                    return error.InvalidArgument;
                }
            }
            filter.origin = qualified_origin;
            filter.session_id = session[sep + 1 ..];
        } else {
            filter.session_id = session;
        }
    }
    return filter;
}

fn invalidArgument(stdout: *std.Io.File.Writer, message: []const u8) !void {
    try status.writeDiagnostic(stdout, .human, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    try stdout.interface.writeAll("\n");
    try help_mod.renderUsage(stdout, usage);
    try stdout.flush();
}

fn shouldUseRedaction(mode: RedactionMode, redacted_by_default: bool) bool {
    return switch (mode) {
        .auto => redacted_by_default,
        .redacted => true,
        .full => false,
    };
}

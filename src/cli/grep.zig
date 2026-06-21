const std = @import("std");
const config_mod = @import("../store/config.zig");
const index_mod = @import("../store/index.zig");
const store_mod = @import("../store/store.zig");
const redact_mod = @import("../privacy/redact.zig");
const content_search = @import("../store/content_search.zig");
const date_util = @import("../util/date.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const status = @import("status.zig");
const arg_parse = @import("arg_parse.zig");

pub const usage = specs.grep_usage;

const default_limit: usize = 20;
const default_context_tokens: usize = 12;

const RedactionMode = enum {
    auto,
    redacted,
    full,
};

const GrepOptions = struct {
    format: output_mod.Format = .human,
    origin: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,
    since_raw: ?[:0]const u8 = null,
    until_raw: ?[:0]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    limit: usize = default_limit,
    context_tokens: usize = default_context_tokens,
    query: ?[:0]const u8 = null,
    redaction_mode: RedactionMode = .auto,
    content: bool = false,
};

const SessionFilter = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

const JsonMatch = struct {
    entry_kind: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    step_hash: []const u8,
    timestamp: i64,
    label: []const u8,
    snippet: []const u8,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };

    const raw_query = options.query orelse {
        try missingQuery(&stdout, options.format);
        return;
    };

    const trimmed_query = std.mem.trim(u8, raw_query, " \t\r\n");
    if (trimmed_query.len == 0) {
        try arg_parse.invalidArg(&stdout, options.format, usage, "Query must not be empty.");
        return;
    }

    if (options.since_ms != null and options.until_ms_exclusive != null and options.since_ms.? >= options.until_ms_exclusive.?) {
        try arg_parse.invalidArg(&stdout, options.format, usage, "--since must be earlier than or equal to --until.");
        return;
    }

    const session_filter = try resolveSessionFilter(&stdout, options);

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
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

    if (options.content) {
        try runContentSearch(
            io,
            gpa,
            &stdout,
            &store,
            &loaded_config,
            trimmed_query,
            session_filter,
            options,
            use_redaction,
        );
        try stdout.flush();
        return;
    }

    const match_query = try buildMatchQuery(gpa, trimmed_query);
    defer gpa.free(match_query);

    const matches = store.index.searchEntries(gpa, .{
        .match_query = match_query,
        .origin = session_filter.origin,
        .session_id = session_filter.session_id,
        .since_ms = options.since_ms,
        .until_ms_exclusive = options.until_ms_exclusive,
        .limit = options.limit,
        .context_tokens = options.context_tokens,
    }) catch |err| {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "search_failed",
            .message = "Failed to search the SQLite index.",
            .hint = @errorName(err),
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer index_mod.freeSearchRows(gpa, matches);

    switch (options.format) {
        .human => try writeHuman(
            &stdout,
            gpa,
            trimmed_query,
            matches,
            use_redaction,
            loaded_config.value.privacy.custom_literals,
        ),
        .json => {
            if (!use_redaction) {
                try output_mod.writeEnvelope(&stdout, usage.name, .{
                    .query = trimmed_query,
                    .origin = session_filter.origin,
                    .session = session_filter.session_id,
                    .since = options.since_raw,
                    .until = options.until_raw,
                    .limit = options.limit,
                    .context = options.context_tokens,
                    .redacted = false,
                    .matches = matches,
                });
            } else {
                const json_matches = try buildJsonMatches(
                    gpa,
                    matches,
                    loaded_config.value.privacy.custom_literals,
                );
                defer freeJsonMatches(gpa, json_matches);
                try output_mod.writeEnvelope(&stdout, usage.name, .{
                    .query = trimmed_query,
                    .origin = session_filter.origin,
                    .session = session_filter.session_id,
                    .since = options.since_raw,
                    .until = options.until_raw,
                    .limit = options.limit,
                    .context = options.context_tokens,
                    .redacted = true,
                    .matches = json_matches,
                });
            }
        },
    }
    try stdout.flush();
}

fn runContentSearch(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    loaded_config: *config_mod.Loaded,
    trimmed_query: []const u8,
    session_filter: SessionFilter,
    options: GrepOptions,
    use_redaction: bool,
) !void {
    const content_matches = content_search.searchBlobContent(io, gpa, store, .{
        .query = trimmed_query,
        .origin = session_filter.origin,
        .session_id = session_filter.session_id,
        .since_ms = options.since_ms,
        .until_ms_exclusive = options.until_ms_exclusive,
        .limit = options.limit,
        .context_tokens = options.context_tokens,
    }) catch |err| {
        try status.writeDiagnostic(stdout, options.format, usage.name, .{
            .code = "content_search_failed",
            .message = "Failed to search blob content.",
            .hint = @errorName(err),
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer content_search.freeContentMatches(gpa, content_matches);

    switch (options.format) {
        .human => try writeContentHuman(
            stdout,
            gpa,
            trimmed_query,
            content_matches,
            use_redaction,
            loaded_config.value.privacy.custom_literals,
        ),
        .json => {
            const json_matches = try buildContentJsonMatches(
                gpa,
                content_matches,
                loaded_config.value.privacy.custom_literals,
            );
            defer freeJsonMatches(gpa, json_matches);
            try output_mod.writeEnvelope(stdout, usage.name, .{
                .query = trimmed_query,
                .origin = session_filter.origin,
                .session = session_filter.session_id,
                .since = options.since_raw,
                .until = options.until_raw,
                .limit = options.limit,
                .context = options.context_tokens,
                .redacted = use_redaction,
                .content = true,
                .matches = json_matches,
            });
        },
    }
}

fn writeContentHuman(
    stdout: *std.Io.File.Writer,
    gpa: std.mem.Allocator,
    query: []const u8,
    matches: []const content_search.ContentMatch,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !void {
    if (matches.len == 0) {
        try stdout.interface.print("No content matches for \"{s}\".\n", .{query});
        return;
    }

    var ts_buf: [32]u8 = undefined;
    for (matches, 0..) |match, i| {
        const rendered_snippet = if (use_redaction) try redact_mod.redactAlloc(gpa, match.snippet, .{
            .custom_literals = custom_literals,
        }) else match.snippet;
        defer if (use_redaction) gpa.free(rendered_snippet);

        if (i > 0) try stdout.interface.writeAll("\n");
        try stdout.interface.print("{s}  {s}/{s}  turn {s}  content {s}  step {s}\n", .{
            status.formatTimestamp(match.timestamp, &ts_buf),
            match.origin,
            match.session_id,
            match.turn_id,
            match.path,
            match.step_hash[0..@min(12, match.step_hash.len)],
        });
        try stdout.interface.print("  {s}\n", .{rendered_snippet});
    }
}

fn buildContentJsonMatches(
    gpa: std.mem.Allocator,
    matches: []const content_search.ContentMatch,
    custom_literals: []const []const u8,
) ![]const JsonMatch {
    const json_matches = try gpa.alloc(JsonMatch, matches.len);
    errdefer gpa.free(json_matches);

    for (matches, 0..) |match, i| {
        json_matches[i] = .{
            .entry_kind = "content",
            .origin = match.origin,
            .session_id = match.session_id,
            .turn_id = match.turn_id,
            .step_hash = match.step_hash,
            .timestamp = match.timestamp,
            .label = match.path,
            .snippet = try redact_mod.redactAlloc(gpa, match.snippet, .{
                .custom_literals = custom_literals,
            }),
        };
    }

    return json_matches;
}

fn writeHuman(
    stdout: *std.Io.File.Writer,
    gpa: std.mem.Allocator,
    query: []const u8,
    matches: []const index_mod.SearchRow,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !void {
    if (matches.len == 0) {
        try stdout.interface.print("No matches for \"{s}\".\n", .{query});
        return;
    }

    var ts_buf: [32]u8 = undefined;
    for (matches, 0..) |match, i| {
        const rendered_snippet = if (use_redaction) try redact_mod.redactAlloc(gpa, match.snippet, .{
            .custom_literals = custom_literals,
        }) else match.snippet;
        defer if (use_redaction) gpa.free(rendered_snippet);
        var source_buf: [128]u8 = undefined;
        const source = formatEntryLabel(&source_buf, match.entry_kind, match.label);

        if (i > 0) try stdout.interface.writeAll("\n");
        try stdout.interface.print("{s}  {s}/{s}  turn {s}  {s}  step {s}\n", .{
            status.formatTimestamp(match.timestamp, &ts_buf),
            match.origin,
            match.session_id,
            match.turn_id,
            source,
            match.step_hash[0..@min(12, match.step_hash.len)],
        });
        try stdout.interface.print("  {s}\n", .{rendered_snippet});
    }
}

fn buildJsonMatches(
    gpa: std.mem.Allocator,
    matches: []const index_mod.SearchRow,
    custom_literals: []const []const u8,
) ![]const JsonMatch {
    const json_matches = try gpa.alloc(JsonMatch, matches.len);
    errdefer gpa.free(json_matches);

    for (matches, 0..) |match, i| {
        json_matches[i] = .{
            .entry_kind = match.entry_kind,
            .origin = match.origin,
            .session_id = match.session_id,
            .turn_id = match.turn_id,
            .step_hash = match.step_hash,
            .timestamp = match.timestamp,
            .label = match.label,
            .snippet = try redact_mod.redactAlloc(gpa, match.snippet, .{
                .custom_literals = custom_literals,
            }),
        };
    }

    return json_matches;
}

fn freeJsonMatches(gpa: std.mem.Allocator, matches: []const JsonMatch) void {
    for (matches) |match| gpa.free(@constCast(match.snippet));
    gpa.free(matches);
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !GrepOptions {
    var options: GrepOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--content")) {
            options.content = true;
        } else if (std.mem.eql(u8, arg, "--origin")) {
            options.origin = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--origin requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--session")) {
            options.session = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--session requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--since")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--since requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.since_ms = date_util.parseUtcDateMidnight(value) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --since date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.since_raw = value;
        } else if (std.mem.eql(u8, arg, "--until")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--until requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.until_ms_exclusive = date_util.parseUtcDateEndExclusive(value) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --until date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.until_raw = value;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--limit requires an integer value.");
                return error.InvalidArgument;
            };
            options.limit = std.fmt.parseUnsigned(usize, value, 10) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --limit value.");
                return error.InvalidArgument;
            };
            if (options.limit == 0) {
                try arg_parse.invalidArg(stdout, options.format, usage, "--limit must be greater than zero.");
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--context")) {
            const value = iter.next() orelse {
                try arg_parse.invalidArg(stdout, options.format, usage, "--context requires an integer value.");
                return error.InvalidArgument;
            };
            options.context_tokens = std.fmt.parseUnsigned(usize, value, 10) catch {
                try arg_parse.invalidArg(stdout, options.format, usage, "Invalid --context value.");
                return error.InvalidArgument;
            };
            if (options.context_tokens == 0) {
                try arg_parse.invalidArg(stdout, options.format, usage, "--context must be greater than zero.");
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
        } else if (options.query == null) {
            options.query = arg;
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

fn resolveSessionFilter(stdout: *std.Io.File.Writer, options: GrepOptions) !SessionFilter {
    var filter: SessionFilter = .{ .origin = options.origin };
    if (options.session) |session| {
        if (std.mem.indexOfScalar(u8, session, '/')) |sep| {
            const qualified_origin = session[0..sep];
            if (filter.origin) |origin| {
                if (!std.mem.eql(u8, origin, qualified_origin)) {
                    try arg_parse.invalidArg(stdout, options.format, usage, "--origin does not match the origin prefix embedded in --session.");
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

fn buildMatchQuery(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (count > 0) try out.appendSlice(gpa, " AND ");
        try appendQuotedToken(&out, gpa, token);
        count += 1;
    }

    if (count == 0) return error.InvalidArgument;
    return out.toOwnedSlice(gpa);
}

fn appendQuotedToken(out: *std.ArrayList(u8), gpa: std.mem.Allocator, token: []const u8) !void {
    try out.append(gpa, '"');
    for (token) |byte| {
        if (byte == '"') {
            try out.append(gpa, '"');
            try out.append(gpa, '"');
        } else {
            try out.append(gpa, byte);
        }
    }
    try out.append(gpa, '"');
}

fn describeEntry(entry_kind: []const u8, label: []const u8) []const u8 {
    if (std.mem.eql(u8, entry_kind, "message")) return if (std.mem.eql(u8, label, "assistant")) "message assistant" else if (std.mem.eql(u8, label, "user")) "message user" else "message";
    if (std.mem.eql(u8, entry_kind, "tool_args")) return "tool args";
    if (std.mem.eql(u8, entry_kind, "tool_result")) return "tool result";
    return entry_kind;
}

fn formatEntryLabel(buf: *[128]u8, entry_kind: []const u8, label: []const u8) []const u8 {
    if (std.mem.eql(u8, entry_kind, "message")) return describeEntry(entry_kind, label);
    return std.fmt.bufPrint(buf, "{s} {s}", .{ describeEntry(entry_kind, label), label }) catch describeEntry(entry_kind, label);
}

fn missingQuery(stdout: *std.Io.File.Writer, format: output_mod.Format) !void {
    if (format == .json) {
        try status.writeDiagnostic(stdout, .json, usage.name, .{
            .code = "missing_query",
            .message = "A search query is required.",
        });
        try stdout.flush();
        std.process.exit(1);
    }

    try help_mod.renderUsage(stdout, usage);
    try stdout.flush();
    std.process.exit(1);
}

fn shouldUseRedaction(mode: RedactionMode, redacted_by_default: bool) bool {
    return switch (mode) {
        .auto => redacted_by_default,
        .redacted => true,
        .full => false,
    };
}

test "buildMatchQuery: single token becomes quoted" {
    const gpa = std.testing.allocator;
    const result = try buildMatchQuery(gpa, "hello");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "buildMatchQuery: multiple tokens joined with AND" {
    const gpa = std.testing.allocator;
    const result = try buildMatchQuery(gpa, "hello world");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"hello\" AND \"world\"", result);
}

test "buildMatchQuery: empty string returns InvalidArgument" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, buildMatchQuery(gpa, ""));
}

test "appendQuotedToken: escapes embedded quotes" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendQuotedToken(&out, gpa, "a\"b");
    const result = try out.toOwnedSlice(gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"a\"\"b\"", result);
}

test "describeEntry: maps known entry kinds" {
    try std.testing.expectEqualStrings("message", describeEntry("message", "ignored"));
    try std.testing.expectEqualStrings("message assistant", describeEntry("message", "assistant"));
    try std.testing.expectEqualStrings("message user", describeEntry("message", "user"));
    try std.testing.expectEqualStrings("tool args", describeEntry("tool_args", "ignored"));
    try std.testing.expectEqualStrings("tool result", describeEntry("tool_result", "ignored"));
    try std.testing.expectEqualStrings("unknown", describeEntry("unknown", "fallback"));
}

test "formatEntryLabel: formats entry kind with label" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("message", formatEntryLabel(&buf, "message", "ignored"));
    try std.testing.expectEqualStrings("tree ignored", formatEntryLabel(&buf, "tree", "ignored"));
}

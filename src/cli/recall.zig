const std = @import("std");
const config_mod = @import("../store/config.zig");
const index_mod = @import("../store/index.zig");
const output_mod = @import("output.zig");
const help_mod = @import("help.zig");
const redact_mod = @import("../privacy/redact.zig");
const session_arg = @import("session_arg.zig");
const specs = @import("specs.zig");
const status = @import("status.zig");
const step_line = @import("step_line.zig");
const store_mod = @import("../store/store.zig");
const outcome_mod = @import("../store/outcome.zig");

pub const usage = specs.recall_usage;

const default_limit: usize = 20;
const search_context_tokens: usize = 12;
const search_candidate_multiplier: usize = 8;

const RedactionMode = enum {
    auto,
    redacted,
    full,
};

const RecallOptions = struct {
    format: output_mod.Format = .human,
    origin: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,
    path: ?[:0]const u8 = null,
    outcome: ?[:0]const u8 = null,
    limit: usize = default_limit,
    query: ?[:0]const u8 = null,
    redaction_mode: RedactionMode = .auto,
};

const SessionFilter = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

const RecallMatch = struct {
    row: index_mod.RecallRow,
    evidence: ?[]u8 = null,

    fn deinit(self: *RecallMatch, gpa: std.mem.Allocator) void {
        index_mod.freeRecallRow(gpa, self.row);
        if (self.evidence) |value| gpa.free(value);
        self.* = undefined;
    }
};

const JsonRecallMatch = struct {
    hash: []const u8,
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    timestamp: i64,
    outcome: []const u8,
    git_commit: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_dirty: ?bool = null,
    preview: []const u8,
    evidence: ?[]const u8 = null,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        error.InvalidArgument => return,
        else => return err,
    };

    const trimmed_query = if (options.query) |value| std.mem.trim(u8, value, " \t\r\n") else null;
    if (options.path == null and (trimmed_query == null or trimmed_query.?.len == 0)) {
        try invalidArgument(&stdout, options.format, "Recall requires a query, a --path filter, or both.");
        return;
    }
    if (trimmed_query != null and trimmed_query.?.len == 0) {
        try invalidArgument(&stdout, options.format, "Query must not be empty.");
        return;
    }

    const session_filter = try resolveSessionFilter(&stdout, options);
    const outcome_filter = try parseOutcomeFilter(&stdout, options);

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

    const search_rows = if (trimmed_query) |query| blk: {
        const match_query = try buildMatchQuery(gpa, query);
        defer gpa.free(match_query);
        break :blk try store.index.searchEntries(gpa, .{
            .match_query = match_query,
            .origin = session_filter.origin,
            .session_id = session_filter.session_id,
            .since_ms = null,
            .until_ms_exclusive = null,
            .limit = options.limit * search_candidate_multiplier,
            .context_tokens = search_context_tokens,
        });
    } else &.{};
    defer if (trimmed_query != null) index_mod.freeSearchRows(gpa, search_rows);

    var matches: std.ArrayList(RecallMatch) = .empty;
    defer {
        for (matches.items) |*match| match.deinit(gpa);
        matches.deinit(gpa);
    }

    if (options.path) |path| {
        const rows = try store.index.listRecallStepsForPath(gpa, .{
            .path = path,
            .origin = session_filter.origin,
            .session_id = session_filter.session_id,
            .outcome = outcome_filter,
            .limit = options.limit * search_candidate_multiplier,
        });
        defer index_mod.freeRecallRows(gpa, rows);

        for (rows) |row| {
            const search_match = if (trimmed_query != null) findSearchRow(search_rows, row.hash) else null;
            if (trimmed_query != null and search_match == null) continue;

            try matches.append(gpa, .{
                .row = try dupRecallRow(gpa, row),
                .evidence = if (search_match) |hit| try gpa.dupe(u8, hit.snippet) else null,
            });
        }
    } else {
        for (search_rows) |row| {
            if (containsRecallStep(matches.items, row.step_hash)) continue;
            const recall_row = (try store.index.getRecallStepByHash(gpa, row.step_hash)) orelse continue;
            errdefer index_mod.freeRecallRow(gpa, recall_row);
            if (outcome_filter) |expected| {
                if (recall_row.outcome == null or !std.mem.eql(u8, recall_row.outcome.?, expected)) continue;
            }

            try matches.append(gpa, .{
                .row = recall_row,
                .evidence = try gpa.dupe(u8, row.snippet),
            });
        }
    }

    std.mem.sort(RecallMatch, matches.items, {}, lessRecallMatch);
    if (matches.items.len > options.limit) {
        for (matches.items[options.limit..]) |*match| match.deinit(gpa);
        matches.shrinkRetainingCapacity(options.limit);
    }

    switch (options.format) {
        .human => try writeHuman(
            io,
            gpa,
            &stdout,
            &store,
            matches.items,
            use_redaction,
            loaded_config.value.privacy.custom_literals,
        ),
        .json => {
            const json_matches = try buildJsonMatches(
                io,
                gpa,
                &stdout,
                &store,
                matches.items,
                use_redaction,
                loaded_config.value.privacy.custom_literals,
            );
            defer freeJsonMatches(gpa, json_matches);

            try output_mod.writeEnvelope(&stdout, usage.name, .{
                .query = trimmed_query,
                .path = options.path,
                .origin = session_filter.origin,
                .session = session_filter.session_id,
                .outcome = outcome_filter,
                .limit = options.limit,
                .redacted = use_redaction,
                .matches = json_matches,
            });
        },
    }

    try stdout.flush();
}

fn writeHuman(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    matches: []const RecallMatch,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !void {
    if (matches.len == 0) {
        try stdout.interface.writeAll("No recall matches.\n");
        return;
    }

    var ts_buf: [32]u8 = undefined;
    for (matches, 0..) |match, i| {
        const preview = try previewAllocForMatch(io, gpa, stdout, store, match.row, use_redaction, custom_literals);
        defer gpa.free(preview);

        const evidence = if (match.evidence) |snippet|
            if (use_redaction) try redact_mod.redactAlloc(gpa, snippet, .{ .custom_literals = custom_literals }) else snippet
        else
            null;
        defer if (match.evidence != null and use_redaction and evidence != null) gpa.free(evidence.?);

        if (i > 0) try stdout.interface.writeAll("\n");
        try stdout.interface.print("{s}  {s}/{s}  turn {s}  {s}  step {s}\n", .{
            status.formatTimestamp(match.row.timestamp, &ts_buf),
            match.row.origin,
            match.row.session_id,
            match.row.turn_id,
            outcomeLabel(match.row.outcome),
            match.row.hash[0..@min(12, match.row.hash.len)],
        });
        if (match.row.git_commit) |commit| {
            try stdout.interface.print("  git {s}@{s}{s}\n", .{
                match.row.git_branch orelse "(detached)",
                commit[0..@min(12, commit.len)],
                if (match.row.git_dirty orelse false) "*" else "",
            });
        }
        try stdout.interface.print("  {s}\n", .{preview});
        if (evidence) |snippet| {
            try stdout.interface.print("  evidence: {s}\n", .{snippet});
        }
    }
}

fn buildJsonMatches(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    matches: []const RecallMatch,
    use_redaction: bool,
    custom_literals: []const []const u8,
) ![]const JsonRecallMatch {
    const json_matches = try gpa.alloc(JsonRecallMatch, matches.len);
    errdefer gpa.free(json_matches);

    for (matches, 0..) |match, i| {
        const preview = try previewAllocForMatch(io, gpa, stdout, store, match.row, use_redaction, custom_literals);
        errdefer {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                gpa.free(@constCast(json_matches[j].preview));
                if (json_matches[j].evidence) |value| gpa.free(@constCast(value));
            }
        }

        const evidence = if (match.evidence) |snippet|
            if (use_redaction) try redact_mod.redactAlloc(gpa, snippet, .{ .custom_literals = custom_literals }) else try gpa.dupe(u8, snippet)
        else
            null;

        json_matches[i] = .{
            .hash = match.row.hash,
            .origin = match.row.origin,
            .session_id = match.row.session_id,
            .turn_id = match.row.turn_id,
            .timestamp = match.row.timestamp,
            .outcome = outcomeLabel(match.row.outcome),
            .git_commit = match.row.git_commit,
            .git_branch = match.row.git_branch,
            .git_dirty = match.row.git_dirty,
            .preview = preview,
            .evidence = evidence,
        };
    }

    return json_matches;
}

fn freeJsonMatches(gpa: std.mem.Allocator, matches: []const JsonRecallMatch) void {
    for (matches) |match| {
        gpa.free(@constCast(match.preview));
        if (match.evidence) |value| gpa.free(@constCast(value));
    }
    gpa.free(matches);
}

fn previewAllocForMatch(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    row: index_mod.RecallRow,
    use_redaction: bool,
    custom_literals: []const []const u8,
) ![]u8 {
    return step_line.previewAllocForRow(
        io,
        gpa,
        stdout,
        .human,
        store,
        .{
            .hash = row.hash,
            .origin = row.origin,
            .session_id = row.session_id,
            .turn_id = row.turn_id,
            .timestamp = row.timestamp,
            .git_commit = row.git_commit,
            .git_branch = row.git_branch,
            .git_dirty = row.git_dirty,
        },
        usage.name,
        use_redaction,
        custom_literals,
    );
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !RecallOptions {
    var options: RecallOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--origin")) {
            options.origin = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--origin requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--session")) {
            options.session = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--session requires a value.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--path")) {
            options.path = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--path requires a file path.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--outcome")) {
            options.outcome = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--outcome requires success, failure, or unknown.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--limit")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--limit requires an integer value.");
                return error.InvalidArgument;
            };
            options.limit = std.fmt.parseUnsigned(usize, value, 10) catch {
                try invalidArgument(stdout, options.format, "Invalid --limit value.");
                return error.InvalidArgument;
            };
            if (options.limit == 0) {
                try invalidArgument(stdout, options.format, "--limit must be greater than zero.");
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

fn resolveSessionFilter(stdout: *std.Io.File.Writer, options: RecallOptions) !SessionFilter {
    var filter: SessionFilter = .{ .origin = options.origin };
    if (options.session) |session| {
        if (std.mem.indexOfScalar(u8, session, '/')) |sep| {
            const qualified_origin = session[0..sep];
            if (filter.origin) |origin| {
                if (!std.mem.eql(u8, origin, qualified_origin)) {
                    try invalidArgument(stdout, options.format, "--origin does not match the origin prefix embedded in --session.");
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

fn parseOutcomeFilter(stdout: *std.Io.File.Writer, options: RecallOptions) !?[]const u8 {
    const raw = options.outcome orelse return null;
    if (std.mem.eql(u8, raw, "success")) return "success";
    if (std.mem.eql(u8, raw, "failure")) return "failure";
    if (std.mem.eql(u8, raw, "unknown")) return "unknown";
    try invalidArgument(stdout, options.format, "Invalid --outcome value; use success, failure, or unknown.");
    return error.InvalidArgument;
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

fn containsRecallStep(matches: []const RecallMatch, hash: []const u8) bool {
    for (matches) |match| {
        if (std.mem.eql(u8, match.row.hash, hash)) return true;
    }
    return false;
}

fn findSearchRow(rows: []const index_mod.SearchRow, hash: []const u8) ?index_mod.SearchRow {
    for (rows) |row| {
        if (std.mem.eql(u8, row.step_hash, hash)) return row;
    }
    return null;
}

fn dupRecallRow(gpa: std.mem.Allocator, row: index_mod.RecallRow) !index_mod.RecallRow {
    return .{
        .hash = try gpa.dupe(u8, row.hash),
        .origin = try gpa.dupe(u8, row.origin),
        .session_id = try gpa.dupe(u8, row.session_id),
        .turn_id = try gpa.dupe(u8, row.turn_id),
        .timestamp = row.timestamp,
        .outcome = if (row.outcome) |value| try gpa.dupe(u8, value) else null,
        .git_commit = if (row.git_commit) |value| try gpa.dupe(u8, value) else null,
        .git_branch = if (row.git_branch) |value| try gpa.dupe(u8, value) else null,
        .git_dirty = row.git_dirty,
    };
}

fn lessRecallMatch(_: void, a: RecallMatch, b: RecallMatch) bool {
    const a_rank = outcomeRank(a.row.outcome);
    const b_rank = outcomeRank(b.row.outcome);
    if (a_rank != b_rank) return a_rank < b_rank;
    if (a.row.timestamp != b.row.timestamp) return a.row.timestamp > b.row.timestamp;
    return std.mem.lessThan(u8, a.row.hash, b.row.hash);
}

fn outcomeRank(raw: ?[]const u8) u8 {
    return switch (outcome_mod.parseLabel(raw)) {
        .failure => 0,
        .unknown => 1,
        .success => 2,
    };
}

fn outcomeLabel(raw: ?[]const u8) []const u8 {
    return outcome_mod.parseLabel(raw).label();
}

fn invalidArgument(stdout: *std.Io.File.Writer, format: output_mod.Format, message: []const u8) !void {
    try status.writeDiagnostic(stdout, format, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    if (format == .human) {
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(stdout, usage);
    }
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

test "outcomeRank: orders failure < unknown < success" {
    try std.testing.expect(outcomeRank("failure") < outcomeRank("success"));
    try std.testing.expect(outcomeRank("failure") < outcomeRank("unknown"));
    try std.testing.expect(outcomeRank("unknown") < outcomeRank("success"));
}

test "outcomeLabel: returns human-readable labels" {
    try std.testing.expectEqualStrings("failure", outcomeLabel("failure"));
    try std.testing.expectEqualStrings("unknown", outcomeLabel("unknown"));
    try std.testing.expectEqualStrings("success", outcomeLabel("success"));
}

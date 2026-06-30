const std = @import("std");
const date_util = @import("../util/date.zig");
const eval_mod = @import("../store/eval.zig");
const git_mod = @import("../util/git.zig");
const store_mod = @import("../store/store.zig");
const arg_parse = @import("arg_parse.zig");
const version_mod = @import("../version.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const status = @import("status.zig");

pub const usage = specs.eval_usage;

const default_lookahead_ms: i64 = 24 * 60 * 60 * 1000;
const max_eval_steps: usize = 1000;

const EvalOptions = struct {
    format: output_mod.Format = .human,
    origin: ?[:0]const u8 = null,
    session: ?[:0]const u8 = null,
    commit_rev: ?[:0]const u8 = null,
    range_spec: ?[:0]const u8 = null,
    since_raw: ?[:0]const u8 = null,
    until_raw: ?[:0]const u8 = null,
    since_ms: ?i64 = null,
    until_ms_exclusive: ?i64 = null,
    lookahead_ms: i64 = default_lookahead_ms,
    include_steps: bool = false,
    list: bool = false,
};

const SessionTarget = struct {
    origin: []const u8,
    session_id: []const u8,
};

const Scope = struct {
    kind: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    rev: ?[]const u8 = null,
    range: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
    session_count: i64 = 0,
    step_count: i64 = 0,
};

const CurrentAssessment = struct {
    classification: []const u8,
    confidence: []const u8,
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
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_argument",
            .message = "--since must be earlier than --until.",
        });
        try stdout.flush();
        return;
    }
    if ((options.session != null and (options.commit_rev != null or options.range_spec != null)) or
        (options.commit_rev != null and options.range_spec != null))
    {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_argument",
            .message = "--session, --commit, and --range are mutually exclusive evaluation scopes.",
        });
        try stdout.flush();
        return;
    }

    if (options.list and
        (options.session != null or options.commit_rev != null or options.range_spec != null or
            options.since_ms != null or options.until_ms_exclusive != null))
    {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "invalid_argument",
            .message = "--list is mutually exclusive with evaluation scope flags (--session, --commit, --range, --since, --until).",
        });
        try stdout.flush();
        return;
    }

    var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    // --list mode: dump stored evaluation summaries
    if (options.list) {
        if (options.format != .json) {
            try status.writeDiagnostic(&stdout, options.format, usage.name, .{
                .code = "format_required",
                .message = "--list requires --json.",
            });
            try stdout.flush();
            return;
        }
        const rows = try store.index.listEvaluations(gpa, options.origin, null, 1000);
        defer store_mod.freeEvalSummaryRows(gpa, rows);

        try output_mod.writeEnvelope(&stdout, usage.name, .{
            .evals = rows,
        });
        try stdout.flush();
        return;
    }

    const resolved_scope = try resolveEvaluationScope(io, gpa, &store, options, &stdout);
    defer {
        if (resolved_scope.target) |target| {
            gpa.free(target.origin);
            gpa.free(target.session_id);
        }
        store_mod.freeTimelineRows(gpa, resolved_scope.rows);
    }

    const scoped_steps = try loadTimelineSteps(io, gpa, &store, resolved_scope.rows);
    defer scoped_steps.deinit(gpa);

    if (scoped_steps.inputs.len == 0) {
        try status.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "session_not_found",
            .message = "No steps recorded for the selected evaluation scope.",
        });
        try stdout.flush();
        return;
    }

    const in_scope = try eval_mod.evaluateSession(gpa, scoped_steps.inputs);
    defer in_scope.deinit(gpa);

    const last_timestamp = scoped_steps.inputs[scoped_steps.inputs.len - 1].timestamp;
    const follow_up = try loadAndEvaluateFollowUp(io, gpa, &store, last_timestamp, options.lookahead_ms);
    defer eval_mod.freeFollowUpAssessment(gpa, follow_up);

    const current = CurrentAssessment{
        .classification = currentClassification(in_scope.classification, follow_up),
        .confidence = if (follow_up.signals.len > 0) "high" else in_scope.confidence,
    };

    const pattern_rows = try rowsForTimelineScope(gpa, &store, null, null, null, null);
    defer store_mod.freeTimelineRows(gpa, pattern_rows);
    const pattern_steps = try loadTimelineSteps(io, gpa, &store, pattern_rows);
    defer pattern_steps.deinit(gpa);

    const patterns = try eval_mod.patternAssociations(gpa, pattern_steps.inputs, scoped_steps.inputs, in_scope);
    defer gpa.free(patterns);

    const scope = resolved_scope.scope;

    // Compute captured evidence hash and persist eval object.
    const step_hashes = try gpa.alloc([]const u8, scoped_steps.inputs.len);
    defer gpa.free(step_hashes);
    for (scoped_steps.inputs, 0..) |input, i| {
        step_hashes[i] = input.hash;
    }
    const evidence_hash = try eval_mod.capturedEvidenceHash(gpa, step_hashes);
    defer gpa.free(evidence_hash);

    const eval_obj = eval_mod.EvalObject{
        .assessment = in_scope,
        .evaluation_scope = scopeToEvalScope(scope),
        .evaluated_at = nowMs(),
        .agit_version = version_mod.value,
        .captured_evidence_hash = evidence_hash,
    };
    const eval_obj_hash = try store.writeEval(io, gpa, eval_obj);
    const eval_hash_hex = eval_obj_hash.toHex();

    // Compute per-step signal assessments when --include-steps is set.
    const StepAssessment = struct {
        hash: []const u8,
        turn_id: []const u8,
        timestamp: i64,
        signals: eval_mod.SignalCounts,
    };
    var step_assessments: std.ArrayList(StepAssessment) = .empty;
    defer step_assessments.deinit(gpa);
    if (options.include_steps) {
        for (scoped_steps.inputs, 0..) |input, i| {
            try step_assessments.append(gpa, .{
                .hash = input.hash,
                .turn_id = resolved_scope.rows[i].turn_id,
                .timestamp = input.timestamp,
                .signals = eval_mod.collectStepSignals(input),
            });
        }
    }

    switch (options.format) {
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .scope = scope,
            .eval_hash = &eval_hash_hex,
            .association_confidence = resolved_scope.association_confidence,
            .in_scope_assessment = in_scope,
            .follow_up_assessment = follow_up,
            .current_assessment = current,
            .patterns = patterns,
            .step_assessments = step_assessments.items,
        }),
        .human => try writeHuman(&stdout, scope, in_scope, follow_up, current, patterns),
    }
    try stdout.flush();
}

const ResolvedScope = struct {
    target: ?SessionTarget = null,
    rows: []const store_mod.TimelineRow,
    scope: Scope,
    association_confidence: []const u8,
};

const LoadedSteps = struct {
    parsed: []std.json.Parsed(store_mod.Step),
    inputs: []eval_mod.SessionStep,

    fn deinit(self: LoadedSteps, gpa: std.mem.Allocator) void {
        for (self.parsed) |parsed| {
            var mutable = parsed;
            mutable.deinit();
        }
        gpa.free(self.parsed);
        gpa.free(self.inputs);
    }
};

fn loadTimelineSteps(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    step_rows: []const store_mod.TimelineRow,
) !LoadedSteps {
    var parsed: std.ArrayList(std.json.Parsed(store_mod.Step)) = .empty;
    errdefer {
        for (parsed.items) |item| {
            var mutable = item;
            mutable.deinit();
        }
        parsed.deinit(gpa);
    }
    var inputs: std.ArrayList(eval_mod.SessionStep) = .empty;
    errdefer inputs.deinit(gpa);

    for (step_rows) |row| {
        const hash = store_mod.Hash.fromHex(row.hash) catch continue;
        const parsed_step = try store.readStep(io, gpa, hash);
        try parsed.append(gpa, parsed_step);
        try inputs.append(gpa, .{
            .hash = row.hash,
            .timestamp = row.timestamp,
            .step = parsed.items[parsed.items.len - 1].value,
        });
    }

    return .{
        .parsed = try parsed.toOwnedSlice(gpa),
        .inputs = try inputs.toOwnedSlice(gpa),
    };
}

fn loadAndEvaluateFollowUp(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    last_timestamp: i64,
    lookahead_ms: i64,
) !eval_mod.FollowUpAssessment {
    if (lookahead_ms <= 0) {
        return .{ .classification_delta = "none", .signals = try gpa.alloc(eval_mod.FollowUpSignal, 0) };
    }

    const rows = try store.index.listRecentSteps(gpa, .{
        .since_ms = last_timestamp + 1,
        .until_ms_exclusive = last_timestamp + lookahead_ms + 1,
        .limit = 200,
    });
    defer store_mod.freeTimelineRows(gpa, rows);

    var parsed: std.ArrayList(std.json.Parsed(store_mod.Step)) = .empty;
    defer {
        for (parsed.items) |item| {
            var mutable = item;
            mutable.deinit();
        }
        parsed.deinit(gpa);
    }
    var inputs: std.ArrayList(eval_mod.SessionStep) = .empty;
    defer inputs.deinit(gpa);

    for (rows) |row| {
        const hash = store_mod.Hash.fromHex(row.hash) catch continue;
        const parsed_step = try store.readStep(io, gpa, hash);
        try parsed.append(gpa, parsed_step);
        try inputs.append(gpa, .{
            .hash = row.hash,
            .timestamp = row.timestamp,
            .step = parsed.items[parsed.items.len - 1].value,
        });
    }

    return eval_mod.detectFollowUpSignals(gpa, inputs.items, last_timestamp, lookahead_ms);
}

fn writeHuman(
    stdout: *std.Io.File.Writer,
    scope: Scope,
    in_scope: eval_mod.Assessment,
    follow_up: eval_mod.FollowUpAssessment,
    current: CurrentAssessment,
    patterns: []const eval_mod.PatternAssociation,
) !void {
    try stdout.interface.print("eval {s}", .{scope.kind});
    if (scope.origin) |origin| try stdout.interface.print(" {s}", .{origin});
    if (scope.session_id) |session_id| try stdout.interface.print("/{s}", .{session_id});
    try stdout.interface.print("\n\nclassification: {s} ({s} confidence)\n", .{ current.classification, current.confidence });
    try stdout.interface.print("in scope:      {s} ({s} confidence)\n", .{ in_scope.classification, in_scope.confidence });
    try stdout.interface.print("follow-up:     {s} ({d} signal(s))\n\n", .{ follow_up.classification_delta, follow_up.signals.len });

    try writeDimension(stdout, "goal clarity", in_scope.dimensions.goal_clarity);
    try writeDimension(stdout, "execution focus", in_scope.dimensions.execution_focus);
    try writeDimension(stdout, "failure recovery", in_scope.dimensions.failure_recovery);
    try writeDimension(stdout, "verification", in_scope.dimensions.verification);
    try writeDimension(stdout, "completion signal", in_scope.dimensions.completion_signal);
    try writeDimension(stdout, "churn risk", in_scope.dimensions.churn_risk);

    if (patterns.len > 0) {
        try stdout.interface.writeAll("\npatterns:\n");
        for (patterns) |pattern| {
            try stdout.interface.print("  {s}: {s} ({d} support, {s} confidence)\n", .{
                pattern.phrase,
                pattern.association,
                pattern.support,
                pattern.confidence,
            });
        }
    }
}

fn writeDimension(stdout: *std.Io.File.Writer, label: []const u8, dimension: eval_mod.DimensionReport) !void {
    try stdout.interface.print("{s}: {s} score={d} confidence={s}\n", .{ label, dimension.rating, dimension.score, dimension.confidence });
    for (dimension.reasons) |reason| try stdout.interface.print("  - {s}\n", .{reason});
}

fn currentClassification(in_scope: []const u8, follow_up: eval_mod.FollowUpAssessment) []const u8 {
    if (follow_up.signals.len == 0) return in_scope;
    if (std.mem.eql(u8, in_scope, "good")) return "mixed";
    return in_scope;
}

fn resolveSessionArg(
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    session_arg: ?[:0]const u8,
    origin_arg: ?[:0]const u8,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
) !SessionTarget {
    if (session_arg) |value| {
        if (std.mem.indexOfScalar(u8, value, '/')) |sep| {
            return .{
                .origin = try gpa.dupe(u8, value[0..sep]),
                .session_id = try gpa.dupe(u8, value[sep + 1 ..]),
            };
        }
        if (origin_arg) |origin| {
            return .{
                .origin = try gpa.dupe(u8, origin),
                .session_id = try gpa.dupe(u8, value),
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

fn resolveEvaluationScope(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    options: EvalOptions,
    stdout: *std.Io.File.Writer,
) !ResolvedScope {
    if (options.commit_rev) |rev| {
        const rows = try rowsForCommit(io, gpa, store, options.origin, rev, stdout, options.format);
        return .{
            .rows = rows,
            .scope = .{
                .kind = "commit",
                .origin = options.origin,
                .rev = rev,
                .session_count = countSessions(rows),
                .step_count = @intCast(rows.len),
            },
            .association_confidence = "medium",
        };
    }

    if (options.range_spec) |range| {
        const rows = try rowsForRange(io, gpa, store, options.origin, range, stdout, options.format);
        return .{
            .rows = rows,
            .scope = .{
                .kind = "range",
                .origin = options.origin,
                .range = range,
                .session_count = countSessions(rows),
                .step_count = @intCast(rows.len),
            },
            .association_confidence = "medium",
        };
    }

    if (options.session != null) {
        const target = try resolveSessionArg(gpa, store, options.session, options.origin, stdout, options.format);
        errdefer {
            gpa.free(target.origin);
            gpa.free(target.session_id);
        }
        const rows = try rowsForTimelineScope(gpa, store, target.origin, target.session_id, options.since_ms, options.until_ms_exclusive);
        return .{
            .target = target,
            .rows = rows,
            .scope = .{
                .kind = "session",
                .origin = target.origin,
                .session_id = target.session_id,
                .since = options.since_raw,
                .until = options.until_raw,
                .session_count = countSessions(rows),
                .step_count = @intCast(rows.len),
            },
            .association_confidence = "high",
        };
    }

    if (options.since_ms != null or options.until_ms_exclusive != null) {
        const rows = try rowsForTimelineScope(gpa, store, options.origin, null, options.since_ms, options.until_ms_exclusive);
        return .{
            .rows = rows,
            .scope = .{
                .kind = "window",
                .origin = options.origin,
                .since = options.since_raw,
                .until = options.until_raw,
                .session_count = countSessions(rows),
                .step_count = @intCast(rows.len),
            },
            .association_confidence = "high",
        };
    }

    const target = try resolveSessionArg(gpa, store, options.session, options.origin, stdout, options.format);
    errdefer {
        gpa.free(target.origin);
        gpa.free(target.session_id);
    }
    const rows = try rowsForTimelineScope(gpa, store, target.origin, target.session_id, null, null);
    return .{
        .target = target,
        .rows = rows,
        .scope = .{
            .kind = "session",
            .origin = target.origin,
            .session_id = target.session_id,
            .since = options.since_raw,
            .until = options.until_raw,
            .session_count = countSessions(rows),
            .step_count = @intCast(rows.len),
        },
        .association_confidence = "high",
    };
}

fn rowsForTimelineScope(
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    origin: ?[]const u8,
    session_id: ?[]const u8,
    since_ms: ?i64,
    until_ms_exclusive: ?i64,
) ![]const store_mod.TimelineRow {
    const rows = try store.index.listRecentSteps(gpa, .{
        .origin = origin,
        .session_id = session_id,
        .since_ms = since_ms,
        .until_ms_exclusive = until_ms_exclusive,
        .limit = max_eval_steps,
    });
    std.mem.sort(store_mod.TimelineRow, @constCast(rows), {}, lessByTimeThenHash);
    return rows;
}

fn rowsForCommit(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    origin: ?[]const u8,
    rev: []const u8,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
) ![]const store_mod.TimelineRow {
    const git_cwd = std.Io.Dir.cwd();
    const commit = try git_mod.resolveRevision(io, gpa, git_cwd, rev) orelse {
        try writeScopeDiagnostic(stdout, format, "git_revision_not_found", "Could not resolve the requested git revision.");
        try stdout.flush();
        std.process.exit(1);
    };
    defer gpa.free(commit);

    const parent_rev = try std.fmt.allocPrint(gpa, "{s}^", .{rev});
    defer gpa.free(parent_rev);
    const parent = try git_mod.resolveRevision(io, gpa, git_cwd, parent_rev);
    defer if (parent) |value| gpa.free(value);

    var list: std.ArrayList(store_mod.TimelineRow) = .empty;
    errdefer {
        for (list.items) |row| store_mod.freeTimelineRow(gpa, row);
        list.deinit(gpa);
    }

    if (parent) |value| try appendRowsForCommit(gpa, store, &list, origin, value);
    try appendRowsForCommit(gpa, store, &list, origin, commit);
    std.mem.sort(store_mod.TimelineRow, list.items, {}, lessByTimeThenHash);
    return try list.toOwnedSlice(gpa);
}

fn rowsForRange(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    origin: ?[]const u8,
    range: []const u8,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
) ![]const store_mod.TimelineRow {
    const sep = std.mem.indexOf(u8, range, "..") orelse {
        try writeScopeDiagnostic(stdout, format, "invalid_argument", "Invalid --range value; use A..B.");
        try stdout.flush();
        std.process.exit(1);
    };
    const start = range[0..sep];
    const end = range[sep + 2 ..];
    if (start.len == 0 or end.len == 0) {
        try writeScopeDiagnostic(stdout, format, "invalid_argument", "Invalid --range value; use A..B.");
        try stdout.flush();
        std.process.exit(1);
    }

    const git_cwd = std.Io.Dir.cwd();
    const start_resolved = try git_mod.resolveRevision(io, gpa, git_cwd, start) orelse {
        try writeScopeDiagnostic(stdout, format, "git_revision_not_found", "Could not resolve the range start revision.");
        try stdout.flush();
        std.process.exit(1);
    };
    defer gpa.free(start_resolved);
    const end_resolved = try git_mod.resolveRevision(io, gpa, git_cwd, end) orelse {
        try writeScopeDiagnostic(stdout, format, "git_revision_not_found", "Could not resolve the range end revision.");
        try stdout.flush();
        std.process.exit(1);
    };
    defer gpa.free(end_resolved);

    const commits = try git_mod.listRangeCommits(io, gpa, git_cwd, start_resolved, end_resolved) orelse {
        try writeScopeDiagnostic(stdout, format, "range_lookup_failed", "Could not list commits in the requested range.");
        try stdout.flush();
        std.process.exit(1);
    };
    defer git_mod.freeCommitList(gpa, commits);

    var list: std.ArrayList(store_mod.TimelineRow) = .empty;
    errdefer {
        for (list.items) |row| store_mod.freeTimelineRow(gpa, row);
        list.deinit(gpa);
    }

    try appendRowsForCommit(gpa, store, &list, origin, start_resolved);
    for (commits) |commit| try appendRowsForCommit(gpa, store, &list, origin, commit);
    std.mem.sort(store_mod.TimelineRow, list.items, {}, lessByTimeThenHash);
    return try list.toOwnedSlice(gpa);
}

fn appendRowsForCommit(
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    list: *std.ArrayList(store_mod.TimelineRow),
    origin: ?[]const u8,
    commit: []const u8,
) !void {
    const rows = try store.index.listStepsByGitCommit(gpa, commit);
    defer gpa.free(rows);
    for (rows) |row| {
        if (origin) |expected| {
            if (!std.mem.eql(u8, expected, row.origin)) {
                store_mod.freeTimelineRow(gpa, row);
                continue;
            }
        }
        try list.append(gpa, row);
    }
}

fn lessByTimeThenHash(_: void, a: store_mod.TimelineRow, b: store_mod.TimelineRow) bool {
    if (a.timestamp != b.timestamp) return a.timestamp < b.timestamp;
    return std.mem.lessThan(u8, a.hash, b.hash);
}

fn nowMs() i64 {
    var tv: std.posix.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

fn scopeToEvalScope(scope: Scope) eval_mod.EvalScope {
    return .{
        .kind = scope.kind,
        .origin = scope.origin,
        .session_id = scope.session_id,
        .rev = scope.rev,
        .range = scope.range,
        .since = scope.since,
        .until = scope.until,
    };
}

fn countSessions(rows: []const store_mod.TimelineRow) i64 {
    var count: i64 = 0;
    for (rows, 0..) |row, i| {
        var seen = false;
        for (rows[0..i]) |prev| {
            if (std.mem.eql(u8, row.origin, prev.origin) and std.mem.eql(u8, row.session_id, prev.session_id)) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return count;
}

fn writeScopeDiagnostic(stdout: *std.Io.File.Writer, format: output_mod.Format, code: []const u8, message: []const u8) !void {
    try status.writeDiagnostic(stdout, format, usage.name, .{
        .code = code,
        .message = message,
    });
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !EvalOptions {
    var options: EvalOptions = .{};
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
        } else if (std.mem.eql(u8, arg, "--commit")) {
            options.commit_rev = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--commit requires a git revision.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--range")) {
            options.range_spec = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--range requires a git revision range.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--since")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--since requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.since_ms = date_util.parseUtcDateMidnight(value) catch {
                try invalidArgument(stdout, options.format, "Invalid --since date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.since_raw = value;
        } else if (std.mem.eql(u8, arg, "--until")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--until requires a YYYY-MM-DD value.");
                return error.InvalidArgument;
            };
            options.until_ms_exclusive = date_util.parseUtcDateEndExclusive(value) catch {
                try invalidArgument(stdout, options.format, "Invalid --until date; use YYYY-MM-DD.");
                return error.InvalidArgument;
            };
            options.until_raw = value;
        } else if (std.mem.eql(u8, arg, "--lookahead")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--lookahead requires a duration like 24h or 0.");
                return error.InvalidArgument;
            };
            options.lookahead_ms = parseLookahead(value) catch {
                try invalidArgument(stdout, options.format, "Invalid --lookahead value; use Nh, Nd, or 0.");
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--no-lookahead")) {
            options.lookahead_ms = 0;
        } else if (std.mem.eql(u8, arg, "--include-steps")) {
            options.include_steps = true;
        } else if (std.mem.eql(u8, arg, "--list")) {
            options.list = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else {
            try invalidArgument(stdout, options.format, "Unknown option.");
            return error.InvalidArgument;
        }
    }
    return options;
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
}

fn parseLookahead(value: []const u8) !i64 {
    if (std.mem.eql(u8, value, "0")) return 0;
    if (value.len < 2) return error.InvalidArgument;
    const suffix = value[value.len - 1];
    const amount = try std.fmt.parseInt(i64, value[0 .. value.len - 1], 10);
    if (amount < 0) return error.InvalidArgument;
    return switch (suffix) {
        'h' => amount * 60 * 60 * 1000,
        'd' => amount * 24 * 60 * 60 * 1000,
        else => error.InvalidArgument,
    };
}

test "parseLookahead: parses hours" {
    try std.testing.expectEqual(@as(i64, 3600000), try parseLookahead("1h"));
    try std.testing.expectEqual(@as(i64, 7200000), try parseLookahead("2h"));
}

test "parseLookahead: parses days" {
    try std.testing.expectEqual(@as(i64, 86400000), try parseLookahead("1d"));
    try std.testing.expectEqual(@as(i64, 172800000), try parseLookahead("2d"));
}

test "parseLookahead: zero is valid" {
    try std.testing.expectEqual(@as(i64, 0), try parseLookahead("0"));
}

test "parseLookahead: rejects invalid input" {
    try std.testing.expectError(error.InvalidCharacter, parseLookahead("abc"));
    try std.testing.expectError(error.InvalidArgument, parseLookahead("-1h"));
    try std.testing.expectError(error.InvalidArgument, parseLookahead("3x"));
    try std.testing.expectError(error.InvalidArgument, parseLookahead(""));
}

test "countSessions: counts unique sessions only" {
    const rows = [_]store_mod.TimelineRow{
        .{ .origin = "a", .session_id = "s1", .turn_id = "t1", .hash = "h1", .timestamp = 1 },
        .{ .origin = "a", .session_id = "s1", .turn_id = "t2", .hash = "h2", .timestamp = 2 },
        .{ .origin = "a", .session_id = "s2", .turn_id = "t1", .hash = "h3", .timestamp = 3 },
    };
    try std.testing.expectEqual(@as(i64, 2), countSessions(&rows));
}

test "countSessions: empty slice returns 0" {
    const rows = [_]store_mod.TimelineRow{};
    try std.testing.expectEqual(@as(i64, 0), countSessions(&rows));
}

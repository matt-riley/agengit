const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

pub const EvalScope = struct {
    kind: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    rev: ?[]const u8 = null,
    range: ?[]const u8 = null,
    since: ?[]const u8 = null,
    until: ?[]const u8 = null,
};

pub const EvalObject = struct {
    type: []const u8 = "eval",
    assessment: Assessment,
    evaluation_scope: EvalScope,
    evaluated_at: i64,
    agit_version: []const u8,
    captured_evidence_hash: []const u8,
};

/// Compute a deterministic BLAKE3 hash over sorted step hashes.
/// Returns a 64-char lowercase hex string. Caller owns the returned memory.
pub fn capturedEvidenceHash(gpa: std.mem.Allocator, step_hashes: []const []const u8) ![]const u8 {
    const sorted = try gpa.alloc([]const u8, step_hashes.len);
    defer gpa.free(sorted);
    @memcpy(sorted, step_hashes);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var hasher = std.crypto.hash.Blake3.init(.{});
    for (sorted) |h| hasher.update(h);
    var digest: [hash_mod.digest_len]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try gpa.dupe(u8, &hex);
}

pub const Rating = enum {
    good,
    mixed,
    bad,
    unknown,

    pub fn label(self: Rating) []const u8 {
        return switch (self) {
            .good => "good",
            .mixed => "mixed",
            .bad => "bad",
            .unknown => "unknown",
        };
    }
};

pub const Confidence = enum {
    low,
    medium,
    high,

    pub fn label(self: Confidence) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

pub const SignalCounts = struct {
    concrete_terms: i64 = 0,
    success_criteria_phrases: i64 = 0,
    tool_calls: i64 = 0,
    related_tool_calls: i64 = 0,
    error_results: i64 = 0,
    recovered_errors: i64 = 0,
    repeated_failures: i64 = 0,
    verification_commands: i64 = 0,
    final_summary_terms: i64 = 0,
    repeated_commands: i64 = 0,
    steps: i64 = 0,
};

pub const DimensionReport = struct {
    rating: []const u8,
    score: i64,
    confidence: []const u8,
    reasons: []const []const u8,
    signals: SignalCounts,
};

pub const Dimensions = struct {
    goal_clarity: DimensionReport,
    execution_focus: DimensionReport,
    failure_recovery: DimensionReport,
    verification: DimensionReport,
    completion_signal: DimensionReport,
    churn_risk: DimensionReport,
};

pub const Assessment = struct {
    classification: []const u8,
    confidence: []const u8,
    dimensions: Dimensions,

    pub fn deinit(self: Assessment, gpa: std.mem.Allocator) void {
        freeDimension(gpa, self.dimensions.goal_clarity);
        freeDimension(gpa, self.dimensions.execution_focus);
        freeDimension(gpa, self.dimensions.failure_recovery);
        freeDimension(gpa, self.dimensions.verification);
        freeDimension(gpa, self.dimensions.completion_signal);
        freeDimension(gpa, self.dimensions.churn_risk);
    }
};

pub const SessionStep = struct {
    hash: []const u8,
    timestamp: i64,
    step: object.Step,
};

pub const FollowUpSignal = struct {
    kind: []const u8,
    session_id: []const u8,
    step_hash: []const u8,
    phrase: []const u8,
};

pub const FollowUpAssessment = struct {
    classification_delta: []const u8,
    signals: []const FollowUpSignal,
};

pub const PatternAssociation = struct {
    phrase: []const u8,
    source: []const u8,
    association: []const u8,
    dimension: []const u8,
    support: i64,
    confidence: []const u8,
};

pub fn freeFollowUpAssessment(gpa: std.mem.Allocator, assessment: FollowUpAssessment) void {
    for (assessment.signals) |signal| {
        gpa.free(@constCast(signal.session_id));
        gpa.free(@constCast(signal.step_hash));
    }
    gpa.free(assessment.signals);
}

pub fn evaluateSession(gpa: std.mem.Allocator, steps: []const SessionStep) !Assessment {
    const signals = collectSignals(steps);
    const dimensions = Dimensions{
        .goal_clarity = try scoreGoalClarity(gpa, signals),
        .execution_focus = try scoreExecutionFocus(gpa, signals),
        .failure_recovery = try scoreFailureRecovery(gpa, signals),
        .verification = try scoreVerification(gpa, signals),
        .completion_signal = try scoreCompletionSignal(gpa, signals),
        .churn_risk = try scoreChurnRisk(gpa, signals),
    };
    return .{
        .classification = classify(dimensions),
        .confidence = confidenceFor(signals).label(),
        .dimensions = dimensions,
    };
}

pub fn detectFollowUpSignals(
    gpa: std.mem.Allocator,
    rows: []const SessionStep,
    scoped_last_timestamp: i64,
    lookahead_ms: i64,
) !FollowUpAssessment {
    var signals: std.ArrayList(FollowUpSignal) = .empty;
    errdefer {
        for (signals.items) |signal| {
            gpa.free(@constCast(signal.session_id));
            gpa.free(@constCast(signal.step_hash));
        }
        signals.deinit(gpa);
    }

    const until = scoped_last_timestamp + lookahead_ms;
    for (rows) |row| {
        if (row.timestamp <= scoped_last_timestamp or row.timestamp > until) continue;
        if (findFollowUpPhrase(row.step)) |phrase| {
            const owned_session_id = try gpa.dupe(u8, row.step.session_id);
            errdefer gpa.free(owned_session_id);
            const owned_step_hash = try gpa.dupe(u8, row.hash);
            errdefer gpa.free(owned_step_hash);
            try signals.append(gpa, .{
                .kind = "failure_report",
                .session_id = owned_session_id,
                .step_hash = owned_step_hash,
                .phrase = phrase,
            });
        }
    }

    const owned = try signals.toOwnedSlice(gpa);
    return .{
        .classification_delta = if (owned.len > 0) "downgrade" else "none",
        .signals = owned,
    };
}

pub fn patternAssociations(
    gpa: std.mem.Allocator,
    baseline_steps: []const SessionStep,
    scoped_steps: []const SessionStep,
    assessment: Assessment,
) ![]const PatternAssociation {
    var list: std.ArrayList(PatternAssociation) = .empty;
    errdefer list.deinit(gpa);

    const scoped_verification_support = countVerificationEvidence(scoped_steps);
    if (scoped_verification_support > 0 and std.mem.eql(u8, assessment.dimensions.verification.rating, "good")) {
        const baseline_support = try countBaselineVerificationSupport(gpa, baseline_steps);
        try list.append(gpa, .{
            .phrase = "verification command",
            .source = "tool_args",
            .association = "higher_rated_sessions",
            .dimension = "verification",
            .support = baseline_support,
            .confidence = if (baseline_support >= 3) "medium" else "low",
        });
    }

    const scoped_repeated_failure_support = assessment.dimensions.failure_recovery.signals.repeated_failures;
    if (scoped_repeated_failure_support > 0 and std.mem.eql(u8, assessment.dimensions.failure_recovery.rating, "bad")) {
        const baseline_support = try countBaselineRepeatedFailureSupport(gpa, baseline_steps);
        try list.append(gpa, .{
            .phrase = "repeated failure output",
            .source = "tool_result",
            .association = "lower_rated_sessions",
            .dimension = "failure_recovery",
            .support = baseline_support,
            .confidence = if (baseline_support >= 3) "medium" else "low",
        });
    }

    return try list.toOwnedSlice(gpa);
}

fn freeDimension(gpa: std.mem.Allocator, report: DimensionReport) void {
    gpa.free(report.reasons);
}

const CollectedSignals = struct {
    counts: SignalCounts = .{},
    first_user: []const u8 = "",
    last_assistant: []const u8 = "",
};

fn collectSignals(steps: []const SessionStep) CollectedSignals {
    var out: CollectedSignals = .{};
    out.counts.steps = @intCast(steps.len);

    var previous_command: []const u8 = "";
    var previous_error = false;
    for (steps) |row| {
        for (row.step.messages) |message| {
            if (std.mem.eql(u8, message.role, "user") and out.first_user.len == 0) {
                out.first_user = message.content;
            }
            if (std.mem.eql(u8, message.role, "assistant") and message.content.len > 0) {
                out.last_assistant = message.content;
            }
        }

        for (row.step.tool_calls) |tool_call| {
            out.counts.tool_calls += 1;
            if (isVerificationCommand(tool_call.args)) out.counts.verification_commands += 1;
            if (toolRelatedToPrompt(tool_call.tool_name, tool_call.args, out.first_user)) out.counts.related_tool_calls += 1;
            if (std.mem.eql(u8, previous_command, tool_call.args)) out.counts.repeated_commands += 1;
            previous_command = tool_call.args;

            if (tool_call.result) |result| {
                const has_error = containsAny(result, &failure_terms);
                if (has_error) out.counts.error_results += 1;
                if (previous_error and !has_error) out.counts.recovered_errors += 1;
                if (previous_error and has_error) out.counts.repeated_failures += 1;
                previous_error = has_error;
            }
        }
    }

    out.counts.concrete_terms = countAny(out.first_user, &concrete_terms);
    out.counts.success_criteria_phrases = countAny(out.first_user, &success_terms);
    out.counts.final_summary_terms = countAny(out.last_assistant, &completion_terms);
    return out;
}

fn scoreGoalClarity(gpa: std.mem.Allocator, signals: CollectedSignals) !DimensionReport {
    const score: i64 = @min(100, signals.counts.concrete_terms * 15 + signals.counts.success_criteria_phrases * 20);
    if (score >= 55) return dimension(gpa, .good, score, .medium, &.{"Initial prompt includes concrete task terms or success criteria."}, signals.counts);
    if (score >= 25) return dimension(gpa, .mixed, score, .low, &.{"Initial prompt has some concrete language but limited success criteria."}, signals.counts);
    return dimension(gpa, .bad, score, .medium, &.{"Initial prompt is too vague to infer a clear goal from captured evidence."}, signals.counts);
}

fn scoreExecutionFocus(gpa: std.mem.Allocator, signals: CollectedSignals) !DimensionReport {
    if (signals.counts.tool_calls == 0) return dimension(gpa, .unknown, 0, .low, &.{"No tool calls were captured for focus analysis."}, signals.counts);
    const score = @min(100, @divTrunc(signals.counts.related_tool_calls * 100, signals.counts.tool_calls));
    if (score >= 50) return dimension(gpa, .good, score, .medium, &.{"Tool activity overlaps with terms from the initial prompt."}, signals.counts);
    return dimension(gpa, .mixed, score, .low, &.{"Tool activity has limited textual overlap with the initial prompt."}, signals.counts);
}

fn scoreFailureRecovery(gpa: std.mem.Allocator, signals: CollectedSignals) !DimensionReport {
    if (signals.counts.error_results == 0) return dimension(gpa, .good, 90, .medium, &.{"No obvious tool failure output was captured."}, signals.counts);
    if (signals.counts.recovered_errors > 0) return dimension(gpa, .mixed, 55, .medium, &.{"Captured errors were followed by at least one non-error result."}, signals.counts);
    if (signals.counts.repeated_failures > 0) return dimension(gpa, .bad, 15, .high, &.{"The session repeated failure output without captured recovery."}, signals.counts);
    return dimension(gpa, .mixed, 40, .medium, &.{"Tool failures were captured without enough evidence of recovery."}, signals.counts);
}

fn scoreVerification(gpa: std.mem.Allocator, signals: CollectedSignals) !DimensionReport {
    if (signals.counts.verification_commands > 0) return dimension(gpa, .good, 85, .high, &.{"Captured tool calls include a test, build, or check command."}, signals.counts);
    return dimension(gpa, .bad, 10, .medium, &.{"No test, build, or check command was captured."}, signals.counts);
}

fn scoreCompletionSignal(gpa: std.mem.Allocator, signals: CollectedSignals) !DimensionReport {
    if (signals.counts.final_summary_terms >= 2) return dimension(gpa, .good, 80, .medium, &.{"Final assistant message mentions change or verification signals."}, signals.counts);
    if (signals.counts.final_summary_terms == 1) return dimension(gpa, .mixed, 50, .low, &.{"Final assistant message has a limited completion signal."}, signals.counts);
    return dimension(gpa, .bad, 10, .medium, &.{"Final assistant message does not clearly summarize changes or verification."}, signals.counts);
}

fn scoreChurnRisk(gpa: std.mem.Allocator, signals: CollectedSignals) !DimensionReport {
    const risk = signals.counts.repeated_commands + signals.counts.repeated_failures + @max(@as(i64, 0), signals.counts.steps - 3);
    if (risk == 0) return dimension(gpa, .good, 90, .medium, &.{"No repeated command or repeated failure churn was detected."}, signals.counts);
    if (risk <= 1) return dimension(gpa, .mixed, 55, .medium, &.{"Some repeated activity suggests mild churn risk."}, signals.counts);
    return dimension(gpa, .bad, 20, .high, &.{"Repeated commands or failures suggest high churn risk."}, signals.counts);
}

fn dimension(
    gpa: std.mem.Allocator,
    rating: Rating,
    score: i64,
    confidence: Confidence,
    reasons: []const []const u8,
    signals: SignalCounts,
) !DimensionReport {
    const owned_reasons = try gpa.alloc([]const u8, reasons.len);
    @memcpy(owned_reasons, reasons);
    return .{
        .rating = rating.label(),
        .score = score,
        .confidence = confidence.label(),
        .reasons = owned_reasons,
        .signals = signals,
    };
}

fn classify(dimensions: Dimensions) []const u8 {
    var good: usize = 0;
    var bad: usize = 0;
    const ratings = [_][]const u8{
        dimensions.goal_clarity.rating,
        dimensions.execution_focus.rating,
        dimensions.failure_recovery.rating,
        dimensions.verification.rating,
        dimensions.completion_signal.rating,
        dimensions.churn_risk.rating,
    };
    for (ratings) |rating| {
        if (std.mem.eql(u8, rating, "good")) good += 1;
        if (std.mem.eql(u8, rating, "bad")) bad += 1;
    }
    if (bad >= 3) return "bad";
    if (good >= 4 and bad == 0) return "good";
    if (good == 0 and bad == 0) return "unknown";
    return "mixed";
}

fn confidenceFor(signals: CollectedSignals) Confidence {
    if (signals.counts.steps >= 2 and signals.counts.tool_calls >= 2) return .high;
    if (signals.counts.steps >= 1 and signals.counts.tool_calls >= 1) return .medium;
    return .low;
}

fn containsAny(haystack: []const u8, terms: []const []const u8) bool {
    for (terms) |term| {
        if (containsIgnoreCase(haystack, term)) return true;
    }
    return false;
}

fn countAny(haystack: []const u8, terms: []const []const u8) i64 {
    var count: i64 = 0;
    for (terms) |term| {
        if (containsIgnoreCase(haystack, term)) count += 1;
    }
    return count;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isVerificationCommand(value: []const u8) bool {
    return containsAny(value, &verification_terms);
}

fn countVerificationEvidence(steps: []const SessionStep) i64 {
    var count: i64 = 0;
    for (steps) |row| {
        for (row.step.tool_calls) |tool_call| {
            if (isVerificationCommand(tool_call.args)) count += 1;
        }
    }
    return count;
}

fn countBaselineVerificationSupport(gpa: std.mem.Allocator, steps: []const SessionStep) !i64 {
    var count: i64 = 0;
    for (steps, 0..) |row, i| {
        if (hasEarlierSession(steps[0..i], row.step.origin, row.step.session_id)) continue;
        var report = try evaluateOneSessionFromBaseline(gpa, steps, row.step.origin, row.step.session_id);
        defer report.assessment.deinit(gpa);
        defer report.steps.deinit(gpa);
        if (countVerificationEvidence(report.steps.items) > 0 and std.mem.eql(u8, report.assessment.dimensions.verification.rating, "good")) {
            count += 1;
        }
    }
    return count;
}

fn countBaselineRepeatedFailureSupport(gpa: std.mem.Allocator, steps: []const SessionStep) !i64 {
    var count: i64 = 0;
    for (steps, 0..) |row, i| {
        if (hasEarlierSession(steps[0..i], row.step.origin, row.step.session_id)) continue;
        var report = try evaluateOneSessionFromBaseline(gpa, steps, row.step.origin, row.step.session_id);
        defer report.assessment.deinit(gpa);
        defer report.steps.deinit(gpa);
        if (report.assessment.dimensions.failure_recovery.signals.repeated_failures > 0 and std.mem.eql(u8, report.assessment.dimensions.failure_recovery.rating, "bad")) {
            count += 1;
        }
    }
    return count;
}

const BaselineSessionReport = struct {
    steps: std.ArrayList(SessionStep),
    assessment: Assessment,
};

fn evaluateOneSessionFromBaseline(
    gpa: std.mem.Allocator,
    steps: []const SessionStep,
    origin: []const u8,
    session_id: []const u8,
) !BaselineSessionReport {
    var session_steps: std.ArrayList(SessionStep) = .empty;
    errdefer session_steps.deinit(gpa);
    for (steps) |row| {
        if (std.mem.eql(u8, row.step.origin, origin) and std.mem.eql(u8, row.step.session_id, session_id)) {
            try session_steps.append(gpa, row);
        }
    }
    const assessment = try evaluateSession(gpa, session_steps.items);
    errdefer assessment.deinit(gpa);
    return .{
        .steps = session_steps,
        .assessment = assessment,
    };
}

fn hasEarlierSession(steps: []const SessionStep, origin: []const u8, session_id: []const u8) bool {
    for (steps) |row| {
        if (std.mem.eql(u8, row.step.origin, origin) and std.mem.eql(u8, row.step.session_id, session_id)) return true;
    }
    return false;
}

fn toolRelatedToPrompt(tool_name: []const u8, args: []const u8, prompt: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, prompt, " \t\r\n,.;:!?()[]{}<>\"'`/\\|+-=*&#");
    while (it.next()) |token| {
        if (token.len < 3 or isPromptStopword(token)) continue;
        if (containsIgnoreCase(tool_name, token) or containsIgnoreCase(args, token)) return true;
    }
    return false;
}

fn isPromptStopword(token: []const u8) bool {
    const stopwords = [_][]const u8{
        "the",
        "and",
        "for",
        "that",
        "this",
        "with",
        "from",
        "into",
        "when",
        "then",
        "than",
        "run",
        "use",
        "add",
        "fix",
        "make",
        "should",
        "must",
    };
    for (stopwords) |word| {
        if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

fn findFollowUpPhrase(step: object.Step) ?[]const u8 {
    for (step.messages) |message| {
        if (std.mem.eql(u8, message.role, "user")) {
            for (follow_up_terms) |term| {
                if (containsIgnoreCase(message.content, term)) return term;
            }
        }
    }
    for (step.tool_calls) |tool_call| {
        if (tool_call.result) |result| {
            for (follow_up_terms) |term| {
                if (containsIgnoreCase(result, term)) return term;
            }
        }
    }
    return null;
}

const concrete_terms = [_][]const u8{
    "add",
    "fix",
    "implement",
    "debug",
    "test",
    "refactor",
    "command",
    "json",
    "workflow",
    "build",
    "run",
};

const success_terms = [_][]const u8{
    "should",
    "must",
    "pass",
    "reports",
    "verified",
    "when ",
};

const verification_terms = [_][]const u8{
    "zig build",
    "build test",
    "check-fmt",
    "npm test",
    "go test",
    "cargo test",
    "pytest",
    "make test",
};

const failure_terms = [_][]const u8{
    "error",
    "failed",
    "failure",
    "panic",
    "traceback",
    "not found",
    "permission denied",
};

const completion_terms = [_][]const u8{
    "implemented",
    "fixed",
    "changed",
    "verified",
    "tested",
    "passed",
    "remaining",
};

const follow_up_terms = [_][]const u8{
    "workflow has failed",
    "workflow failed",
    "tests are still failing",
    "that did not work",
    "that didn't work",
    "deployment failed",
    "ci failed",
    "rollback",
    "regression",
};

test "containsIgnoreCase finds mixed-case terms" {
    try std.testing.expect(containsIgnoreCase("The Workflow FAILED", "workflow failed"));
}

test "toolRelatedToPrompt compares meaningful prompt terms against tool activity" {
    try std.testing.expect(toolRelatedToPrompt("bash", "sed -n '1,80p' src/store/eval.zig", "Improve the eval scoring"));
    try std.testing.expect(!toolRelatedToPrompt("bash", "zig build test", "Improve the recall command"));
}

// Characterization tests below pin the six `score*` dimension functions and the
// `evaluateSession` composition. They exercise current thresholds in isolation
// so a silent drift surfaces here rather than in a coarse e2e golden.
// `CollectedSignals` exposes a nested `counts` field (see struct above).

const ToolCallSpec = struct {
    name: []const u8,
    args: []const u8,
    result: ?[]const u8,
};

/// Build a `SessionStep` for eval characterization tests.
///
/// `prompt` becomes the single user message; `assistant` (when non-null and
/// non-empty) becomes an assistant message. Each spec yields one tool call.
/// All messages/tool_calls slices are allocator-owned and must be released via
/// `freeStep`. Message/tool strings themselves are borrowed from the caller
/// (typically string literals) and are not freed here.
fn makeStep(
    gpa: std.mem.Allocator,
    hash: []const u8,
    prompt: []const u8,
    assistant: ?[]const u8,
    tool_calls: []const ToolCallSpec,
) !SessionStep {
    var messages: std.ArrayList(object.StepMessage) = .empty;
    defer messages.deinit(gpa);
    try messages.append(gpa, .{ .role = "user", .content = prompt });
    if (assistant) |content| {
        if (content.len > 0) try messages.append(gpa, .{ .role = "assistant", .content = content });
    }
    const owned_messages = try messages.toOwnedSlice(gpa);
    errdefer gpa.free(owned_messages);

    const owned_calls = try gpa.alloc(object.StepToolCall, tool_calls.len);
    errdefer gpa.free(owned_calls);
    for (tool_calls, 0..) |spec, i| {
        owned_calls[i] = .{
            .tool_name = spec.name,
            .args = spec.args,
            .result = spec.result,
        };
    }

    return .{
        .hash = hash,
        .timestamp = 0,
        .step = .{
            .parent = null,
            .tree = "0" ** 64,
            .session_id = "test-session",
            .origin = "test",
            .turn_id = "test-turn",
            .causes = &.{},
            .timestamp = 0,
            .messages = owned_messages,
            .tool_calls = owned_calls,
        },
    };
}

fn freeStep(gpa: std.mem.Allocator, step: SessionStep) void {
    gpa.free(@constCast(step.step.messages));
    gpa.free(@constCast(step.step.tool_calls));
}

test "makeStep builds a SessionStep with allocated messages and tool_calls" {
    const gpa = std.testing.allocator;
    const step = try makeStep(gpa, "abc", "implement the test", "done and verified", &.{
        .{ .name = "bash", .args = "zig build test", .result = "ok" },
    });
    defer freeStep(gpa, step);
    try std.testing.expectEqual(@as(usize, 2), step.step.messages.len);
    try std.testing.expectEqualStrings("user", step.step.messages[0].role);
    try std.testing.expectEqualStrings("implement the test", step.step.messages[0].content);
    try std.testing.expectEqualStrings("assistant", step.step.messages[1].role);
    try std.testing.expectEqual(@as(usize, 1), step.step.tool_calls.len);
    try std.testing.expectEqualStrings("zig build test", step.step.tool_calls[0].args);
    try std.testing.expect(step.step.tool_calls[0].result != null);
}

test "scoreGoalClarity thresholds: bad/mixed(30)/good(60) with 15/20 per-signal steps" {
    const gpa = std.testing.allocator;
    {
        const signals = CollectedSignals{ .counts = .{ .concrete_terms = 0, .success_criteria_phrases = 0 } };
        const report = try scoreGoalClarity(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("bad", report.rating);
        try std.testing.expectEqual(@as(i64, 0), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // 2*15 = 30 -> below 55 good band, at/above 25 mixed band.
        const signals = CollectedSignals{ .counts = .{ .concrete_terms = 2, .success_criteria_phrases = 0 } };
        const report = try scoreGoalClarity(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("mixed", report.rating);
        try std.testing.expectEqual(@as(i64, 30), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // 1*15 + 2*20 = 55 -> exactly at the good band threshold (>= 55).
        const signals = CollectedSignals{ .counts = .{ .concrete_terms = 1, .success_criteria_phrases = 2 } };
        const report = try scoreGoalClarity(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 55), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        const signals = CollectedSignals{ .counts = .{ .concrete_terms = 4, .success_criteria_phrases = 0 } };
        const report = try scoreGoalClarity(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 60), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
}

test "scoreExecutionFocus thresholds: unknown/good(50)/mixed(30)" {
    const gpa = std.testing.allocator;
    {
        const signals = CollectedSignals{ .counts = .{ .tool_calls = 0 } };
        const report = try scoreExecutionFocus(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("unknown", report.rating);
        try std.testing.expectEqual(@as(i64, 0), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // 5/10 = 50 -> exactly at the good band threshold (>= 50).
        const signals = CollectedSignals{ .counts = .{ .tool_calls = 10, .related_tool_calls = 5 } };
        const report = try scoreExecutionFocus(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 50), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        const signals = CollectedSignals{ .counts = .{ .tool_calls = 10, .related_tool_calls = 6 } };
        const report = try scoreExecutionFocus(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 60), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // 3/10 = 30 -> mixed.
        const signals = CollectedSignals{ .counts = .{ .tool_calls = 10, .related_tool_calls = 3 } };
        const report = try scoreExecutionFocus(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("mixed", report.rating);
        try std.testing.expectEqual(@as(i64, 30), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
}

test "scoreFailureRecovery thresholds: good/mixed(55)/bad/mixed(40)" {
    const gpa = std.testing.allocator;
    {
        const signals = CollectedSignals{ .counts = .{ .error_results = 0 } };
        const report = try scoreFailureRecovery(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 90), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // recovered_errors > 0 -> mixed at 55.
        const signals = CollectedSignals{ .counts = .{ .error_results = 1, .recovered_errors = 1 } };
        const report = try scoreFailureRecovery(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("mixed", report.rating);
        try std.testing.expectEqual(@as(i64, 55), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // repeated_failures > 0 -> bad at 15.
        const signals = CollectedSignals{ .counts = .{ .error_results = 2, .repeated_failures = 1 } };
        const report = try scoreFailureRecovery(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("bad", report.rating);
        try std.testing.expectEqual(@as(i64, 15), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // errors without recovery or repetition -> mixed at 40.
        const signals = CollectedSignals{ .counts = .{ .error_results = 1 } };
        const report = try scoreFailureRecovery(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("mixed", report.rating);
        try std.testing.expectEqual(@as(i64, 40), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
}

test "scoreVerification thresholds: bad without commands, good with one" {
    const gpa = std.testing.allocator;
    {
        const signals = CollectedSignals{ .counts = .{ .verification_commands = 0 } };
        const report = try scoreVerification(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("bad", report.rating);
        try std.testing.expectEqual(@as(i64, 10), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        const signals = CollectedSignals{ .counts = .{ .verification_commands = 1 } };
        const report = try scoreVerification(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 85), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
}

test "scoreCompletionSignal thresholds: bad/mixed(1)/good(2)" {
    const gpa = std.testing.allocator;
    {
        const signals = CollectedSignals{ .counts = .{ .final_summary_terms = 0 } };
        const report = try scoreCompletionSignal(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("bad", report.rating);
        try std.testing.expectEqual(@as(i64, 10), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        const signals = CollectedSignals{ .counts = .{ .final_summary_terms = 1 } };
        const report = try scoreCompletionSignal(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("mixed", report.rating);
        try std.testing.expectEqual(@as(i64, 50), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        const signals = CollectedSignals{ .counts = .{ .final_summary_terms = 2 } };
        const report = try scoreCompletionSignal(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 80), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
}

test "scoreChurnRisk thresholds: good(0)/mixed(<=1)/bad(>=2)" {
    const gpa = std.testing.allocator;
    {
        // risk = 0 + 0 + max(0, 2-3) = 0 -> good.
        const signals = CollectedSignals{ .counts = .{ .steps = 2, .repeated_commands = 0, .repeated_failures = 0 } };
        const report = try scoreChurnRisk(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("good", report.rating);
        try std.testing.expectEqual(@as(i64, 90), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // risk = 1 + 0 + max(0, 3-3) = 1 -> mixed.
        const signals = CollectedSignals{ .counts = .{ .steps = 3, .repeated_commands = 1, .repeated_failures = 0 } };
        const report = try scoreChurnRisk(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("mixed", report.rating);
        try std.testing.expectEqual(@as(i64, 55), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
    {
        // risk = 2 + 0 + max(0, 3-3) = 2 -> bad.
        const signals = CollectedSignals{ .counts = .{ .steps = 3, .repeated_commands = 2, .repeated_failures = 0 } };
        const report = try scoreChurnRisk(gpa, signals);
        defer freeDimension(gpa, report);
        try std.testing.expectEqualStrings("bad", report.rating);
        try std.testing.expectEqual(@as(i64, 20), report.score);
        try std.testing.expect(report.reasons.len > 0);
    }
}

test "evaluateSession composes six dimensions and classifies the session" {
    const gpa = std.testing.allocator;
    const steps = try gpa.alloc(SessionStep, 2);
    errdefer gpa.free(steps);
    var created: usize = 0;
    errdefer for (steps[0..created]) |*step| freeStep(gpa, step.*);
    steps[0] = try makeStep(
        gpa,
        "h1",
        "Implement the test command and json workflow build",
        "Implemented and verified the change.",
        &.{
            .{ .name = "bash", .args = "zig build test", .result = "ok" },
            .{ .name = "bash", .args = "sed test", .result = "error: not found" },
        },
    );
    created += 1;
    steps[1] = try makeStep(
        gpa,
        "h2",
        "that did not work",
        "Fixed the failure and verified again.",
        &.{
            .{ .name = "bash", .args = "sed fix", .result = "panic: boom" },
        },
    );
    defer {
        freeStep(gpa, steps[0]);
        freeStep(gpa, steps[1]);
        gpa.free(steps);
    }

    // Expected collected signals (verify by hand):
    //   concrete_terms=6, success_criteria=0 -> goal clarity good (90)
    //   tool_calls=3, related=2 -> execution focus good (66)
    //   error_results=2, recovered=0, repeated_failures=1 -> failure recovery bad (15)
    //   verification_commands=1 -> verification good (85)
    //   final_summary_terms=2 (fixed, verified) -> completion good (80)
    //   churn risk = 0+1+max(0,2-3)=1 -> mixed (55)
    //   good=4, bad=1 -> classify "mixed"; steps>=2 & tool_calls>=2 -> confidence "high".
    const assessment = try evaluateSession(gpa, steps);
    defer assessment.deinit(gpa);

    try std.testing.expectEqualStrings("mixed", assessment.classification);
    try std.testing.expectEqualStrings("high", assessment.confidence);

    const dims = assessment.dimensions;
    try std.testing.expectEqualStrings("good", dims.goal_clarity.rating);
    try std.testing.expectEqualStrings("good", dims.execution_focus.rating);
    try std.testing.expectEqualStrings("bad", dims.failure_recovery.rating);
    try std.testing.expectEqualStrings("good", dims.verification.rating);
    try std.testing.expectEqualStrings("good", dims.completion_signal.rating);
    try std.testing.expectEqualStrings("mixed", dims.churn_risk.rating);

    // Every dimension derived a concrete (non-unknown) rating for this input.
    try std.testing.expect(dims.goal_clarity.reasons.len > 0);
    try std.testing.expect(dims.execution_focus.reasons.len > 0);
    try std.testing.expect(dims.failure_recovery.reasons.len > 0);
    try std.testing.expect(dims.verification.reasons.len > 0);
    try std.testing.expect(dims.completion_signal.reasons.len > 0);
    try std.testing.expect(dims.churn_risk.reasons.len > 0);
}

// ── Eval object persistence ───────────────────────────────────────────────

/// Serialize an EvalObject as JSON and write it to the object store.
/// Returns the BLAKE3 hash.
pub fn writeEvalDetailed(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    eval: EvalObject,
) !object.WriteDetails {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(eval, .{}, &aw.writer);
    return object.writeDetailed(io, root, aw.writer.buffered());
}

pub fn writeEval(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    eval: EvalObject,
) !object.Hash {
    return (try writeEvalDetailed(io, root, gpa, eval)).hash;
}

/// Read and deserialize an EvalObject from the object store.
/// Caller must call `.deinit()` on the returned value.
pub fn readEval(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    h: object.Hash,
) !std.json.Parsed(EvalObject) {
    const data = try object.read(io, root, gpa, h);
    defer gpa.free(data);
    return std.json.parseFromSlice(EvalObject, gpa, data, .{ .allocate = .alloc_always });
}

test "capturedEvidenceHash is deterministic and sorted" {
    const gpa = std.testing.allocator;
    const hashes = [_][]const u8{ "c" ** 64, "a" ** 64, "b" ** 64 };
    const h1 = try capturedEvidenceHash(gpa, &hashes);
    defer gpa.free(@constCast(h1));

    const reordered = [_][]const u8{ "b" ** 64, "a" ** 64, "c" ** 64 };
    const h2 = try capturedEvidenceHash(gpa, &reordered);
    defer gpa.free(@constCast(h2));

    try std.testing.expectEqualStrings(h1, h2);
    try std.testing.expectEqual(@as(usize, 64), h1.len);
}

test "capturedEvidenceHash empty input" {
    const gpa = std.testing.allocator;
    const empty: [0][]const u8 = .{};
    const h = try capturedEvidenceHash(gpa, &empty);
    defer gpa.free(@constCast(h));
    try std.testing.expectEqual(@as(usize, 64), h.len);
}

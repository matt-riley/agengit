const std = @import("std");
const object = @import("object.zig");

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

const std = @import("std");

const redact_mod = @import("redact.zig");
const store_mod = @import("../store/store.zig");
const config_mod = @import("../store/config.zig");

pub const Finding = struct {
    severity: redact_mod.Severity,
    rule: []const u8,
    source: []const u8,
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    turn_id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

pub const Stats = struct {
    sessions: usize = 0,
    steps: usize = 0,
    trees: usize = 0,
    blobs: usize = 0,
    findings: usize = 0,
};

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    findings: []const Finding,
    stats: Stats,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn clean(self: *const Result) bool {
        return self.findings.len == 0;
    }
};

pub fn scanStore(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    privacy: config_mod.PrivacyConfig,
) !Result {
    const sessions = try store.index.listSessions(gpa);
    defer store_mod.freeSessionRows(gpa, sessions);
    return scanSessionRows(io, gpa, store, privacy, sessions);
}

pub fn scanSessions(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    privacy: config_mod.PrivacyConfig,
    sessions: []const store_mod.SessionRow,
) !Result {
    return scanSessionRows(io, gpa, store, privacy, sessions);
}

fn scanSessionRows(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    privacy: config_mod.PrivacyConfig,
    sessions: []const store_mod.SessionRow,
) !Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var findings: std.ArrayList(Finding) = .empty;
    var stats: Stats = .{};

    var seen_steps = std.StringHashMap(void).init(aa);
    var seen_trees = std.StringHashMap(void).init(aa);
    var seen_blobs = std.StringHashMap(void).init(aa);

    for (sessions) |session| {
        if (session.head_hash == null) continue;
        if (!privacy.originEnabled(session.origin)) continue;
        stats.sessions += 1;

        var current_hash = session.head_hash.?;
        while (true) {
            if (seen_steps.contains(current_hash)) break;
            try seen_steps.put(try aa.dupe(u8, current_hash), {});
            stats.steps += 1;

            const step_hash = try store_mod.Hash.fromHex(current_hash);
            var parsed_step = try store.readStep(io, gpa, step_hash);
            defer parsed_step.deinit();
            const step = parsed_step.value;

            for (step.messages) |message| {
                try appendTextFindings(aa, &findings, &stats, privacy, message.role, message.content, .{
                    .origin = step.origin,
                    .session_id = step.session_id,
                    .turn_id = step.turn_id,
                    .path = null,
                    .hash = current_hash,
                });
            }

            for (step.tool_calls) |tool_call| {
                try appendTextFindings(aa, &findings, &stats, privacy, "tool_args", tool_call.args, .{
                    .origin = step.origin,
                    .session_id = step.session_id,
                    .turn_id = step.turn_id,
                    .path = null,
                    .hash = current_hash,
                });
                if (tool_call.result) |result| {
                    try appendTextFindings(aa, &findings, &stats, privacy, "tool_result", result, .{
                        .origin = step.origin,
                        .session_id = step.session_id,
                        .turn_id = step.turn_id,
                        .path = null,
                        .hash = current_hash,
                    });
                }
            }

            if (!seen_trees.contains(step.tree)) {
                try seen_trees.put(try aa.dupe(u8, step.tree), {});
                stats.trees += 1;
                const tree_hash = try store_mod.Hash.fromHex(step.tree);
                var parsed_tree = try store.readTree(io, gpa, tree_hash);
                defer parsed_tree.deinit();
                for (parsed_tree.value.entries) |entry| {
                    if (seen_blobs.contains(entry.blob)) continue;
                    try seen_blobs.put(try aa.dupe(u8, entry.blob), {});
                    stats.blobs += 1;
                    const blob_hash = try store_mod.Hash.fromHex(entry.blob);
                    const blob = try store.readBlob(io, gpa, blob_hash);
                    defer gpa.free(blob);
                    try appendTextFindings(aa, &findings, &stats, privacy, "snapshot_blob", blob, .{
                        .origin = step.origin,
                        .session_id = step.session_id,
                        .turn_id = step.turn_id,
                        .path = entry.path,
                        .hash = entry.blob,
                    });
                }
            }

            const next_hash = if (step.parent) |parent| try aa.dupe(u8, parent) else null;
            current_hash = next_hash orelse break;
        }
    }

    return .{
        .arena = arena,
        .findings = try findings.toOwnedSlice(aa),
        .stats = stats,
    };
}

const Location = struct {
    origin: []const u8,
    session_id: []const u8,
    turn_id: []const u8,
    path: ?[]const u8,
    hash: ?[]const u8,
};

fn appendTextFindings(
    aa: std.mem.Allocator,
    findings: *std.ArrayList(Finding),
    stats: *Stats,
    privacy: config_mod.PrivacyConfig,
    source: []const u8,
    text: []const u8,
    location: Location,
) !void {
    if (text.len == 0) return;

    const matches = try redact_mod.scanAlloc(aa, text, .{
        .custom_literals = privacy.custom_literals,
    });

    var seen_rules = std.StringHashMap(void).init(aa);
    for (matches) |match| {
        if (seen_rules.contains(match.rule)) continue;
        try seen_rules.put(match.rule, {});
        try findings.append(aa, .{
            .severity = match.severity,
            .rule = match.rule,
            .source = try aa.dupe(u8, source),
            .origin = try aa.dupe(u8, location.origin),
            .session_id = try aa.dupe(u8, location.session_id),
            .turn_id = try aa.dupe(u8, location.turn_id),
            .path = if (location.path) |path| try aa.dupe(u8, path) else null,
            .hash = if (location.hash) |hash| try aa.dupe(u8, hash) else null,
        });
        stats.findings += 1;
    }
}

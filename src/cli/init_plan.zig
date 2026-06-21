const std = @import("std");
const atomic_json_mod = @import("../util/atomic_json.zig");
const path_lookup = @import("../util/path_lookup.zig");

/// Agent metadata shared across init, doctor, uninstall.
pub const AgentMetadata = struct {
    name: []const u8,
    id: []const u8,
    config_path_rel: []const u8,
    dir_path_rel: []const u8,
    /// How agit installs into this agent.
    /// - `json_hooks`: merge agit hooks + `_agit` metadata into a JSON config file.
    /// - `js_extension`: write a generated JS extension file (no JSON config).
    install_kind: InstallKind = .json_hooks,
};

pub const InstallKind = enum {
    json_hooks,
    js_extension,
};

pub const claude = AgentMetadata{
    .name = "Claude Code",
    .id = "claude",
    .config_path_rel = ".claude/settings.json",
    .dir_path_rel = ".claude",
};

pub const codex = AgentMetadata{
    .name = "Codex CLI",
    .id = "codex",
    .config_path_rel = ".codex/hooks.json",
    .dir_path_rel = ".codex",
};

pub const gemini = AgentMetadata{
    .name = "Gemini CLI",
    .id = "gemini",
    .config_path_rel = ".gemini/settings.json",
    .dir_path_rel = ".gemini",
};

pub const copilot = AgentMetadata{
    .name = "Copilot CLI",
    .id = "copilot",
    .config_path_rel = ".copilot/extensions/agit-recorder/extension.mjs",
    .dir_path_rel = ".copilot/extensions/agit-recorder",
    .install_kind = .js_extension,
};

pub const pi = AgentMetadata{
    .name = "Pi",
    .id = "pi",
    .config_path_rel = ".pi/agent/extensions/agit-recorder.js",
    .dir_path_rel = ".pi/agent/extensions",
    .install_kind = .js_extension,
};

// Runtime-iterable array of all agents
var all_agents = [_]AgentMetadata{ claude, codex, gemini, copilot, pi };
pub fn all() []AgentMetadata {
    return &all_agents;
}

/// Check if an agent id (e.g., "claude", "codex", "gemini") is valid.
pub fn isValidId(id: []const u8) bool {
    for (all()) |agent| {
        if (std.mem.eql(u8, agent.id, id)) {
            return true;
        }
    }
    return false;
}

/// Represents the state of a single agent: binary found?, config path, current state, proposed writes.
pub const AgentPlan = struct {
    pub const State = enum {
        /// Agent binary not found in PATH.
        binary_missing,
        /// Binary found, but config is malformed and --force not set.
        config_malformed,
        /// Binary found, config is root non-object and --force not set.
        config_not_object,
        /// Binary found, config is valid or missing — ready to install.
        ready,
    };

    /// Agent metadata.
    agent: AgentMetadata,
    /// Current state.
    state: State,
    /// Full path to config file.
    config_path: []const u8,
    /// Path that was or will be backed up (if applicable).
    backup_path: ?[]const u8,
    /// If config_malformed, the diagnostic.
    malformed_diag: ?atomic_json_mod.MalformedJson,
};

/// Plan for all agents and the overall setup.
pub const Plan = struct {
    /// Per-agent plan records.
    agents: []AgentPlan,
    /// Agent ids selected by user (subset of agents with state==ready).
    selected_agent_ids: []const []const u8,
    /// Whether this is a dry-run.
    dry_run: bool,
    /// Whether --force was set.
    force: bool,
};

/// Build the complete install plan.
///
/// `selected_ids` restricts installation to those agent ids; an empty slice
/// means "all ready agents". Unknown ids return `error.UnknownAgent` before
/// any filesystem access.
pub fn buildPlan(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    home: []const u8,
    selected_ids: []const []const u8,
    force: bool,
    dry_run: bool,
) !Plan {
    for (selected_ids) |id| {
        if (!isValidId(id)) return error.UnknownAgent;
    }
    const select_all = selected_ids.len == 0;

    var agent_plans = std.ArrayList(AgentPlan).empty;
    defer agent_plans.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    for (all()) |agent| {
        const config_path = try std.mem.concat(gpa, u8, &.{ home, "/", agent.config_path_rel });
        defer gpa.free(config_path);

        const binary_found = path_lookup.hasExecutableInPath(io, gpa, environ, agent.id);

        if (!binary_found) {
            try agent_plans.append(gpa, .{
                .agent = agent,
                .state = .binary_missing,
                .config_path = try gpa.dupe(u8, config_path),
                .backup_path = null,
                .malformed_diag = null,
            });
            continue;
        }

        // JS-extension agents have no JSON config to load/merge; agit always
        // (re)writes a self-contained extension file, so they are ready when
        // the binary is present.
        if (agent.install_kind == .js_extension) {
            try agent_plans.append(gpa, .{
                .agent = agent,
                .state = .ready,
                .config_path = try gpa.dupe(u8, config_path),
                .backup_path = null,
                .malformed_diag = null,
            });
            continue;
        }

        const loaded = atomic_json_mod.loadObject(io, aa, config_path) catch |err| {
            return err;
        };

        const state: AgentPlan.State = switch (loaded) {
            .missing, .object => .ready,
            .malformed => if (force) .ready else .config_malformed,
            .not_object => if (force) .ready else .config_not_object,
        };

        const backup_path: ?[]const u8 = if (force and (loaded == .malformed or loaded == .not_object)) backup: {
            // Build a backup path for dry-run display only (not written in dry-run).
            const ts_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
            const timestamp = std.fmt.allocPrint(gpa, "{d}", .{ts_ms}) catch return error.OutOfMemory;
            defer gpa.free(timestamp);
            break :backup try std.fmt.allocPrint(gpa, "{s}.backup-{s}", .{ config_path, timestamp });
        } else null;

        try agent_plans.append(gpa, .{
            .agent = agent,
            .state = state,
            .config_path = try gpa.dupe(u8, config_path),
            .backup_path = backup_path,
            .malformed_diag = if (loaded == .malformed) loaded.malformed else null,
        });
    }

    // Collect selected agent ids that are ready.
    var selected = std.ArrayList([]const u8).empty;
    for (agent_plans.items) |agent_plan| {
        const is_selected = select_all or blk: {
            for (selected_ids) |id| {
                if (std.mem.eql(u8, id, agent_plan.agent.id)) break :blk true;
            }
            break :blk false;
        };
        if (is_selected and agent_plan.state == .ready) {
            try selected.append(gpa, try gpa.dupe(u8, agent_plan.agent.id));
        }
    }

    return .{
        .agents = try agent_plans.toOwnedSlice(gpa),
        .selected_agent_ids = try selected.toOwnedSlice(gpa),
        .dry_run = dry_run,
        .force = force,
    };
}

test "isValidId recognizes all agents" {
    try std.testing.expect(isValidId("claude"));
    try std.testing.expect(isValidId("codex"));
    try std.testing.expect(isValidId("gemini"));
    try std.testing.expect(isValidId("copilot"));
    try std.testing.expect(isValidId("pi"));
    try std.testing.expect(!isValidId("unknown"));
}

test "buildPlan rejects unknown agent ids before touching the filesystem" {
    const gpa = std.testing.allocator;
    const environ = std.process.Environ.empty;

    try std.testing.expectError(
        error.UnknownAgent,
        buildPlan(gpa, undefined, environ, "/tmp", &.{"invalid"}, false, false),
    );
}

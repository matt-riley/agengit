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

/// Get agent metadata by id. Returns null if not found.
pub fn getAgentById(id: []const u8) ?AgentMetadata {
    for (all()) |agent| {
        if (std.mem.eql(u8, agent.id, id)) {
            return agent;
        }
    }
    return null;
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

/// Builder for InitPlan.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    home: []const u8,
    exe: []const u8,
    force: bool,
    dry_run: bool,
    selected: ?std.StringHashMap(void),

    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        home: []const u8,
        exe: []const u8,
        force: bool,
        dry_run: bool,
    ) Builder {
        return .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .home = home,
            .exe = exe,
            .force = force,
            .dry_run = dry_run,
            .selected = null,
        };
    }

    /// Mark a specific agent as selected. Only selected agents will be installed.
    /// Unknown agent names return error.UnknownAgent.
    pub fn selectAgent(self: *Builder, agent_id: []const u8) !void {
        if (!isValidId(agent_id)) {
            return error.UnknownAgent;
        }
        if (self.selected == null) {
            self.selected = std.StringHashMap(void).init(self.gpa);
        }
        try self.selected.?.put(agent_id, {});
    }

    /// Check if an agent is selected (or if no agents have been explicitly selected).
    fn isSelected(self: *const Builder, agent_id: []const u8) bool {
        if (self.selected == null) {
            return true; // No explicit selection means all are selected.
        }
        return self.selected.?.contains(agent_id);
    }

    /// Build the complete plan.
    pub fn build(self: *Builder) !Plan {
        var agent_plans = std.ArrayList(AgentPlan).empty;
        defer agent_plans.deinit(self.gpa);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const aa = arena.allocator();

        for (all()) |agent| {
            const config_path = try std.mem.concat(self.gpa, u8, &.{ self.home, "/", agent.config_path_rel });
            defer self.gpa.free(config_path);

            const binary_found = path_lookup.hasExecutableInPath(self.io, self.gpa, self.environ, agent.id);

            if (!binary_found) {
                try agent_plans.append(self.gpa, .{
                    .agent = agent,
                    .state = .binary_missing,
                    .config_path = try self.gpa.dupe(u8, config_path),
                    .backup_path = null,
                    .malformed_diag = null,
                });
                continue;
            }

            // JS-extension agents have no JSON config to load/merge; agit always
            // (re)writes a self-contained extension file, so they are ready when
            // the binary is present.
            if (agent.install_kind == .js_extension) {
                try agent_plans.append(self.gpa, .{
                    .agent = agent,
                    .state = .ready,
                    .config_path = try self.gpa.dupe(u8, config_path),
                    .backup_path = null,
                    .malformed_diag = null,
                });
                continue;
            }

            const loaded = atomic_json_mod.loadObject(self.io, aa, config_path) catch |err| {
                return err;
            };

            const state: AgentPlan.State = switch (loaded) {
                .missing, .object => .ready,
                .malformed => if (self.force) .ready else .config_malformed,
                .not_object => if (self.force) .ready else .config_not_object,
            };

            const backup_path: ?[]const u8 = if (self.force and (loaded == .malformed or loaded == .not_object)) backup: {
                // Build a backup path for dry-run display only (not written in dry-run).
                const ts_ms = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
                const timestamp = std.fmt.allocPrint(self.gpa, "{d}", .{ts_ms}) catch return error.OutOfMemory;
                defer self.gpa.free(timestamp);
                break :backup try std.fmt.allocPrint(self.gpa, "{s}.backup-{s}", .{ config_path, timestamp });
            } else null;

            try agent_plans.append(self.gpa, .{
                .agent = agent,
                .state = state,
                .config_path = try self.gpa.dupe(u8, config_path),
                .backup_path = backup_path,
                .malformed_diag = if (loaded == .malformed) loaded.malformed else null,
            });
        }

        // Collect selected agent ids that are ready.
        var selected = std.ArrayList([]const u8).empty;
        for (agent_plans.items) |agent_plan| {
            if (self.isSelected(agent_plan.agent.id) and agent_plan.state == .ready) {
                try selected.append(self.gpa, try self.gpa.dupe(u8, agent_plan.agent.id));
            }
        }

        return .{
            .agents = try agent_plans.toOwnedSlice(self.gpa),
            .selected_agent_ids = try selected.toOwnedSlice(self.gpa),
            .dry_run = self.dry_run,
            .force = self.force,
        };
    }

    pub fn deinit(self: *Builder) void {
        if (self.selected) |*sel| {
            sel.deinit();
        }
    }
};

test "isValidId recognizes all agents" {
    try std.testing.expect(isValidId("claude"));
    try std.testing.expect(isValidId("codex"));
    try std.testing.expect(isValidId("gemini"));
    try std.testing.expect(isValidId("copilot"));
    try std.testing.expect(isValidId("pi"));
    try std.testing.expect(!isValidId("unknown"));
}

test "Builder.selectAgent validates agent names" {
    const gpa = std.testing.allocator;
    const environ = std.process.Environ.empty;

    var builder = Builder.init(gpa, undefined, environ, "/tmp", "/bin/agit", false, false);
    defer builder.deinit();

    try builder.selectAgent("claude");
    try builder.selectAgent("codex");

    try std.testing.expectError(error.UnknownAgent, builder.selectAgent("invalid"));
}

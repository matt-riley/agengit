const std = @import("std");
const help_mod = @import("help.zig");

const init_cmd = @import("init.zig");
const uninstall_cmd = @import("uninstall.zig");
const doctor_cmd = @import("doctor.zig");
const status_cmd = @import("status.zig");
const sessions_cmd = @import("sessions.zig");
const log_cmd = @import("log.zig");
const show_cmd = @import("show.zig");
const blame_cmd = @import("blame.zig");
const cat_cmd = @import("cat.zig");
const reindex_cmd = @import("reindex.zig");
const completion_cmd = @import("completion.zig");
const version_cmd = @import("version.zig");

pub const public_commands = [_]help_mod.CommandSpec{
    .{ .name = "init", .summary = "Set up agit in the current repository", .usage = &init_cmd.usage },
    .{ .name = "uninstall", .summary = "Remove agit hooks from agent configurations", .usage = &uninstall_cmd.usage },
    .{ .name = "doctor", .summary = "Check agent hook configurations and store health", .usage = &doctor_cmd.usage },
    .{ .name = "status", .summary = "Show current repository state", .usage = &status_cmd.usage },
    .{ .name = "sessions", .summary = "List recorded agent sessions", .usage = &sessions_cmd.usage },
    .{ .name = "log", .summary = "Show step history for a session", .usage = &log_cmd.usage },
    .{ .name = "show", .summary = "Show details of a step", .usage = &show_cmd.usage },
    .{ .name = "blame", .summary = "Show per-line step attribution for a file", .usage = &blame_cmd.usage },
    .{ .name = "cat", .summary = "Print a raw object by hash", .usage = &cat_cmd.usage },
    .{ .name = "reindex", .summary = "Rebuild the index from the object store", .usage = &reindex_cmd.usage },
    .{ .name = "version", .summary = "Print version information", .usage = &version_cmd.usage },
    .{ .name = "completion", .summary = "Generate shell completion scripts", .usage = &completion_cmd.usage },
};

pub fn usageFor(name: []const u8) ?*const help_mod.UsageSpec {
    for (public_commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command.usage;
    }
    return null;
}

test "public command registry has unique names and usage specs" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();

    for (public_commands) |command| {
        try std.testing.expect(command.usage != null);
        try std.testing.expect(command.name.len > 0);
        try std.testing.expect(command.summary.len > 0);
        try std.testing.expect(!seen.contains(command.name));
        try seen.put(command.name, {});
    }
}

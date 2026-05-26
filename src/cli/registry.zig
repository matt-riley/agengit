const std = @import("std");
const help_mod = @import("help.zig");
const specs = @import("specs.zig");

pub const public_commands = specs.public_commands;

pub fn usageFor(name: []const u8) ?*const help_mod.UsageSpec {
    return specs.usageFor(name);
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

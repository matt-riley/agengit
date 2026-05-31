const std = @import("std");
const adapter_mod = @import("../Adapter.zig");
const claude = @import("claude.zig");
const codex = @import("codex.zig");
const gemini = @import("gemini.zig");
const copilot = @import("copilot.zig");
const pi = @import("pi.zig");

pub const all = [_]adapter_mod.Adapter{
    claude.hook_adapter,
    claude.tool_batch_adapter,
    codex.adapter,
    gemini.adapter,
    copilot.adapter,
    pi.adapter,
};

test "registered adapters declare handler contract" {
    for (all) |adapter| {
        try std.testing.expect(adapter.events.len > 0);
        try std.testing.expect(adapter.parsePayload != null);
        try std.testing.expect(adapter.buildStep != null);
    }
}

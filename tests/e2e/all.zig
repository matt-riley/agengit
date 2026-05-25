test {
    _ = @import("help_snapshot.zig");

    _ = @import("init/fresh.zig");
    _ = @import("init/existing_user_config.zig");
    _ = @import("init/malformed_json.zig");
    _ = @import("init/force.zig");

    _ = @import("uninstall/clean.zig");
    _ = @import("uninstall/malformed.zig");

    _ = @import("hooks/claude_payloads.zig");
    _ = @import("hooks/codex_payloads.zig");
    _ = @import("hooks/gemini_payloads.zig");

    _ = @import("record_replay/concurrent_writers.zig");
    _ = @import("record_replay/crash_recovery.zig");
    _ = @import("record_replay/durable_writes.zig");

    _ = @import("doctor/healthy_store.zig");
    _ = @import("doctor/drifted_store.zig");
}

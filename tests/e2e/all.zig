test {
    _ = @import("help_snapshot.zig");
    _ = @import("completion_snapshot.zig");
    _ = @import("structured_output.zig");
    _ = @import("restore/snapshot_restore.zig");
    _ = @import("object_prefix_resolution.zig");

    _ = @import("init/fresh.zig");
    _ = @import("init/existing_user_config.zig");
    _ = @import("init/malformed_json.zig");
    _ = @import("init/force.zig");
    _ = @import("init/crash_tmp_write.zig");

    _ = @import("uninstall/clean.zig");
    _ = @import("uninstall/malformed.zig");

    _ = @import("hooks/claude_payloads.zig");
    _ = @import("hooks/codex_payloads.zig");
    _ = @import("hooks/gemini_payloads.zig");
    _ = @import("hooks/payload_diagnostics.zig");
    _ = @import("hooks/turn_identity_and_cwd.zig");
    _ = @import("privacy/capture_policy.zig");
    _ = @import("privacy/scan.zig");
    _ = @import("observe/fixture.zig");

    _ = @import("record_replay/concurrent_writers.zig");
    _ = @import("record_replay/crash_recovery.zig");
    _ = @import("record_replay/durable_writes.zig");

    _ = @import("doctor/healthy_store.zig");
    _ = @import("doctor/drifted_store.zig");
    _ = @import("doctor/locks.zig");
    _ = @import("doctor/config_tmp_files.zig");
    _ = @import("doctor/last_hook_error.zig");
    _ = @import("status/non_mutating_open.zig");

    _ = @import("fsck/healthy_store.zig");
    _ = @import("fsck/object_hash_mismatch.zig");
    _ = @import("fsck/reindex_repairs_index.zig");
    _ = @import("gc/prune_and_cleanup.zig");
    _ = @import("git/between.zig");
    _ = @import("blame/attribution.zig");
    _ = @import("watch/live_follow.zig");
    _ = @import("grep/search.zig");
    _ = @import("investigation/views.zig");
    _ = @import("portable_bundle.zig");
    _ = @import("remote_sync.zig");
    _ = @import("analytics/diff_stats.zig");
}

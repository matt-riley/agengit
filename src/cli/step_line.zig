const std = @import("std");
const output_mod = @import("output.zig");
const preview_mod = @import("../store/preview.zig");
const redact_mod = @import("../privacy/redact.zig");
const status = @import("status.zig");
const store_mod = @import("../store/store.zig");

pub const preview_limit: usize = preview_mod.preview_limit;

pub fn writeHumanRow(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    store: *store_mod.Store,
    row: store_mod.TimelineRow,
    command_name: []const u8,
    use_redaction: bool,
    custom_literals: []const []const u8,
) !void {
    const preview = try previewAllocForRow(
        io,
        gpa,
        stdout,
        .human,
        store,
        row,
        command_name,
        use_redaction,
        custom_literals,
    );
    defer gpa.free(preview);

    var ts_buf: [32]u8 = undefined;
    try stdout.interface.print("{s}  {s}/{s}  turn {s}  step {s}\n", .{
        status.formatTimestamp(row.timestamp, &ts_buf),
        row.origin,
        row.session_id,
        row.turn_id,
        row.hash[0..@min(12, row.hash.len)],
    });
    if (row.git_commit) |commit| {
        try stdout.interface.print("  git {s}@{s}{s}\n", .{
            row.git_branch orelse "(detached)",
            commit[0..@min(12, commit.len)],
            if (row.git_dirty orelse false) "*" else "",
        });
    }
    if (row.model) |model| {
        try stdout.interface.print("  model {s}\n", .{model});
    }
    try stdout.interface.print("  {s}\n", .{preview});
}

pub fn previewAllocForRow(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    store: *store_mod.Store,
    row: store_mod.TimelineRow,
    command_name: []const u8,
    use_redaction: bool,
    custom_literals: []const []const u8,
) ![]u8 {
    // Hot path: the index already stores the normalized preview computed at
    // finalize/reindex time, so we only need the per-viewer redaction pass.
    if (row.preview) |stored| {
        if (stored.len > 0) {
            const redacted = if (use_redaction) try redact_mod.redactAlloc(gpa, stored, .{
                .custom_literals = custom_literals,
            }) else stored;
            defer if (use_redaction) gpa.free(redacted);
            return try gpa.dupe(u8, redacted);
        }
    }

    // Fallback for pre-migration or unreindexed steps: re-read the step blob and
    // rebuild the preview exactly as before, so old stores still render.
    const hash = store_mod.Hash.fromHex(row.hash) catch {
        try status.writeDiagnostic(stdout, format, command_name, .{
            .code = "invalid_step_hash",
            .message = "Timeline row contains an invalid step hash.",
            .hash = row.hash,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    var parsed = store.readStep(io, gpa, hash) catch |err| {
        try status.writeDiagnostic(stdout, format, command_name, .{
            .code = "step_read_failed",
            .message = "Failed to read a step referenced by the timeline.",
            .hint = @errorName(err),
            .hash = row.hash,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    defer parsed.deinit();

    const preview_source = preview_mod.choosePreview(parsed.value);
    const preview_text = if (use_redaction) try redact_mod.redactAlloc(gpa, preview_source, .{
        .custom_literals = custom_literals,
    }) else preview_source;
    defer if (use_redaction) gpa.free(preview_text);

    return try preview_mod.normalizePreviewAlloc(gpa, preview_text, preview_limit);
}

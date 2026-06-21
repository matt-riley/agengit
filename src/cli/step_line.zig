const std = @import("std");
const output_mod = @import("output.zig");
const redact_mod = @import("../privacy/redact.zig");
const status = @import("status.zig");
const store_mod = @import("../store/store.zig");

pub const preview_limit: usize = 96;

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

    const preview_source = choosePreview(parsed.value);
    const preview_text = if (use_redaction) try redact_mod.redactAlloc(gpa, preview_source, .{
        .custom_literals = custom_literals,
    }) else preview_source;
    defer if (use_redaction) gpa.free(preview_text);

    return try normalizePreviewAlloc(gpa, preview_text, preview_limit);
}

fn choosePreview(step: store_mod.Step) []const u8 {
    for (step.messages) |message| {
        if (std.mem.eql(u8, message.role, "user") and message.content.len > 0) return message.content;
    }
    for (step.messages) |message| {
        if (std.mem.eql(u8, message.role, "assistant") and message.content.len > 0) return message.content;
    }
    for (step.tool_calls) |tool_call| {
        if (tool_call.result) |result| {
            if (result.len > 0) return result;
        }
        if (tool_call.args.len > 0) return tool_call.args;
        if (tool_call.tool_name.len > 0) return tool_call.tool_name;
    }
    return "(no preview)";
}

fn normalizePreviewAlloc(gpa: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var previous_was_space = false;
    var i: usize = 0;
    while (i < text.len and out.items.len < limit) : (i += 1) {
        const ch = text[i];
        const normalized = switch (ch) {
            '\r', '\n', '\t' => ' ',
            else => ch,
        };

        if (normalized == ' ') {
            if (previous_was_space or out.items.len == 0) continue;
            previous_was_space = true;
        } else {
            previous_was_space = false;
        }
        try out.append(gpa, normalized);
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop().?;
    }

    if (i < text.len and out.items.len > 0) {
        if (out.items.len == limit) _ = out.pop().?;
        try out.appendSlice(gpa, "…");
    }

    if (out.items.len == 0) try out.appendSlice(gpa, "(empty preview)");
    return out.toOwnedSlice(gpa);
}

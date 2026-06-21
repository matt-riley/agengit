const std = @import("std");
const object = @import("object.zig");

pub const preview_limit: usize = 96;

/// Shared single source of truth for the list-view preview: the same selection
/// rule used to render at view time is also applied at finalize/reindex time so
/// the index can serve the per-row preview without re-reading the step blob.
pub fn choosePreview(step: object.Step) []const u8 {
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

/// Collapse whitespace and truncate to `limit` bytes with a trailing `…`
/// ellipsis. The output may be slightly longer than `limit` bytes when the
/// truncation point appends the multi-byte ellipsis. Mirrors what view-time
/// rendering has always produced, so a stored preview is byte-identical to
/// the historical on-the-fly output.
pub fn normalizePreviewAlloc(gpa: std.mem.Allocator, text: []const u8, limit: usize) ![]u8 {
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

/// Produce the final stored form: selection + normalization. Redaction is
/// applied at view time (it depends on the viewer's config), so callers store
/// this string directly as `steps.preview`.
pub fn computePreviewAlloc(gpa: std.mem.Allocator, step: object.Step) ![]u8 {
    return normalizePreviewAlloc(gpa, choosePreview(step), preview_limit);
}

test "choosePreview prefers user, then assistant, then tool output" {
    try std.testing.expectEqualStrings("u1", choosePreview(.{
        .parent = null,
        .tree = "t",
        .session_id = "s",
        .origin = "o",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 0,
        .messages = &.{.{ .role = "user", .content = "u1" }},
        .tool_calls = &.{.{ .tool_name = "Bash", .args = "a1", .result = "r1" }},
    }));
    try std.testing.expectEqualStrings("a1", choosePreview(.{
        .parent = null,
        .tree = "t",
        .session_id = "s",
        .origin = "o",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 0,
        .messages = &.{.{ .role = "assistant", .content = "a1" }},
        .tool_calls = &.{.{ .tool_name = "Bash", .args = "x", .result = "r1" }},
    }));
    try std.testing.expectEqualStrings("r1", choosePreview(.{
        .parent = null,
        .tree = "t",
        .session_id = "s",
        .origin = "o",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 0,
        .messages = &.{},
        .tool_calls = &.{.{ .tool_name = "Bash", .args = "x", .result = "r1" }},
    }));
    try std.testing.expectEqualStrings("(no preview)", choosePreview(.{
        .parent = null,
        .tree = "t",
        .session_id = "s",
        .origin = "o",
        .turn_id = "t1",
        .causes = &.{},
        .timestamp = 0,
        .messages = &.{},
        .tool_calls = &.{},
    }));
}

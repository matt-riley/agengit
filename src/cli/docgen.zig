const std = @import("std");
const specs = @import("specs.zig");

pub const begin_marker = "<!-- BEGIN COMMANDS -->";
pub const end_marker = "<!-- END COMMANDS -->";
pub const synopsis_prefix = "**Synopsis:** `";
pub const public_commands = specs.public_commands;

pub const SynopsisMap = std.StringHashMap([]const u8);

pub const Error = error{
    MissingBeginMarker,
    MissingEndMarker,
    InvalidSynopsisLine,
};

pub fn renderCommandSection(gpa: std.mem.Allocator) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (specs.public_commands, 0..) |command, index| {
        const usage = command.usage orelse unreachable;
        if (index > 0) try out.appendSlice(gpa, "\n");

        try appendFmt(&out, gpa, aa, "### `agit {s}`\n", .{usage.name});
        try appendFmt(&out, gpa, aa, "{s}\n\n", .{usage.description});
        try appendFmt(&out, gpa, aa, "{s}agit {s} {s}`\n\n", .{ synopsis_prefix, usage.name, usage.synopsis });

        if (usage.examples.len > 0) {
            const example = usage.examples[0];
            try out.appendSlice(gpa, "```sh\n");
            try appendFmt(&out, gpa, aa, "# {s}\n", .{example.description});
            if (example.command.len > 0) {
                try appendFmt(&out, gpa, aa, "agit {s} {s}\n", .{ usage.name, example.command });
            } else {
                try appendFmt(&out, gpa, aa, "agit {s}\n", .{usage.name});
            }
            try out.appendSlice(gpa, "```\n");
        }

        if (usage.notes.len > 0) {
            try appendFmt(&out, gpa, aa, "\n**Notes:** {s}\n", .{usage.notes});
        }
    }

    return out.toOwnedSlice(gpa);
}

pub fn rewriteBetweenMarkers(
    gpa: std.mem.Allocator,
    readme_text: []const u8,
    replacement: []const u8,
) ![]u8 {
    const begin_index = std.mem.indexOf(u8, readme_text, begin_marker) orelse return error.MissingBeginMarker;
    const content_start = skipMarkerLine(readme_text, begin_index + begin_marker.len);
    const end_index = std.mem.indexOfPos(u8, readme_text, content_start, end_marker) orelse return error.MissingEndMarker;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, readme_text[0..content_start]);
    try out.appendSlice(gpa, replacement);
    if (replacement.len > 0 and replacement[replacement.len - 1] != '\n') {
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, readme_text[end_index..]);

    return out.toOwnedSlice(gpa);
}

pub fn collectReadmeSynopses(gpa: std.mem.Allocator, readme_text: []const u8) !SynopsisMap {
    var map = SynopsisMap.init(gpa);
    errdefer {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    var lines = std.mem.splitScalar(u8, readme_text, '\n');
    var in_generated = false;
    var saw_begin = false;
    var saw_end = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.eql(u8, line, begin_marker)) {
            in_generated = true;
            saw_begin = true;
            continue;
        }
        if (std.mem.eql(u8, line, end_marker)) {
            saw_end = true;
            break;
        }
        if (!in_generated or !std.mem.startsWith(u8, line, synopsis_prefix)) continue;

        const raw_synopsis = line[synopsis_prefix.len..];
        if (raw_synopsis.len == 0 or raw_synopsis[raw_synopsis.len - 1] != '`') {
            return error.InvalidSynopsisLine;
        }
        const synopsis = raw_synopsis[0 .. raw_synopsis.len - 1];
        if (!std.mem.startsWith(u8, synopsis, "agit ")) return error.InvalidSynopsisLine;

        const command_tail = synopsis["agit ".len..];
        const split_index = std.mem.indexOfScalar(u8, command_tail, ' ') orelse command_tail.len;
        const name = command_tail[0..split_index];
        try map.put(try gpa.dupe(u8, name), try gpa.dupe(u8, synopsis));
    }

    if (!saw_begin) return error.MissingBeginMarker;
    if (!saw_end) return error.MissingEndMarker;
    return map;
}

fn appendFmt(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const rendered = try std.fmt.allocPrint(scratch, fmt, args);
    try out.appendSlice(gpa, rendered);
}

fn skipMarkerLine(text: []const u8, index: usize) usize {
    if (index >= text.len) return index;
    if (text[index] == '\r') {
        if (index + 1 < text.len and text[index + 1] == '\n') return index + 2;
        return index + 1;
    }
    if (text[index] == '\n') return index + 1;
    return index;
}

test "rewriteBetweenMarkers only changes generated block" {
    const gpa = std.testing.allocator;
    const original =
        \\# README
        \\
        \\Before
        \\<!-- BEGIN COMMANDS -->
        \\old
        \\<!-- END COMMANDS -->
        \\After
        \\
    ;
    const replacement =
        \\new
        \\block
        \\
    ;

    const rewritten = try rewriteBetweenMarkers(gpa, original, replacement);
    defer gpa.free(rewritten);

    try std.testing.expectEqualStrings(
        \\# README
        \\
        \\Before
        \\<!-- BEGIN COMMANDS -->
        \\new
        \\block
        \\<!-- END COMMANDS -->
        \\After
        \\
    , rewritten);
}

test "rendered section exposes one synopsis per public command" {
    const gpa = std.testing.allocator;
    const section = try renderCommandSection(gpa);
    defer gpa.free(section);

    const wrapped = try std.fmt.allocPrint(
        gpa,
        "# README\n\n{s}\n{s}{s}",
        .{ begin_marker, section, end_marker },
    );
    defer gpa.free(wrapped);

    var synopses = try collectReadmeSynopses(gpa, wrapped);
    defer {
        var iter = synopses.iterator();
        while (iter.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        synopses.deinit();
    }

    try std.testing.expectEqual(specs.public_commands.len, synopses.count());
    try std.testing.expectEqualStrings("agit init [OPTIONS]", synopses.get("init").?);
    try std.testing.expectEqualStrings("agit version [OPTIONS]", synopses.get("version").?);
    try std.testing.expect(std.mem.indexOf(u8, section, "**Notes:** Blame recording is not yet available.") != null);
}

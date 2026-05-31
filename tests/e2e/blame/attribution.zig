const std = @import("std");
const harness = @import("../support/harness.zig");

test "blame attributes lines to the step that last changed them" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");

    // Session A creates both lines.
    try sandbox.writeRepoFile("file.txt", "line one\nline two\n");
    try recordTurn(&sandbox, "sess-a", "turn-a", "add two lines", "done a");

    // Session B changes only the second line.
    try sandbox.writeRepoFile("file.txt", "line one\nline two changed\n");
    try recordTurn(&sandbox, "sess-b", "turn-b", "edit second line", "done b");

    var blame = try sandbox.run(&.{ "blame", "--json", "file.txt" }, null);
    defer blame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), blame.exit_code);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try parseLines(arena.allocator(), blame.stdout);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line one", lines[0].text);
    try std.testing.expectEqualStrings("line two changed", lines[1].text);
    try std.testing.expectEqualStrings("", lines[2].text);
    // Line one keeps its original attribution; line two points at a new step.
    try std.testing.expect(!std.mem.eql(u8, lines[0].step, lines[1].step));
    // The trailing empty line is unchanged, so it inherits session A's step.
    try std.testing.expectEqualStrings(lines[0].step, lines[2].step);
}

test "blame output is identical after reindex" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("file.txt", "alpha\nbeta\n");
    try recordTurn(&sandbox, "sess-a", "turn-a", "seed", "done a");
    try sandbox.writeRepoFile("file.txt", "alpha\nbeta gamma\n");
    try recordTurn(&sandbox, "sess-b", "turn-b", "extend", "done b");

    var before = try sandbox.run(&.{ "blame", "--json", "file.txt" }, null);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), before.exit_code);

    var reindex = try sandbox.run(&.{"reindex"}, null);
    defer reindex.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), reindex.exit_code);

    var after = try sandbox.run(&.{ "blame", "--json", "file.txt" }, null);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), after.exit_code);

    try std.testing.expectEqualStrings(before.stdout, after.stdout);
}

test "blame reports a friendly error for an unrecorded path" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("file.txt", "only\n");
    try recordTurn(&sandbox, "sess-a", "turn-a", "seed", "done a");

    var blame = try sandbox.run(&.{ "blame", "missing.txt" }, null);
    defer blame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), blame.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, blame.stdout, "No blame recorded") != null);
}

test "blame skips binary files" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("bin.dat", "abc\x00\x01\x02def\n");
    try recordTurn(&sandbox, "sess-a", "turn-a", "seed binary", "done a");

    var blame = try sandbox.run(&.{ "blame", "bin.dat" }, null);
    defer blame.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), blame.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, blame.stdout, "No blame recorded") != null);
}

const Line = struct {
    step: []const u8,
    text: []const u8,
};

/// Parse the blame `--json` envelope into per-line step + text slices, all
/// allocated from `arena` so the caller frees them in one deinit.
fn parseLines(arena: std.mem.Allocator, json: []const u8) ![]Line {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{ .allocate = .alloc_always });
    const data = parsed.value.object.get("data").?.object;
    const arr = data.get("lines").?.array;
    const out = try arena.alloc(Line, arr.items.len);
    for (arr.items, 0..) |item, i| {
        out[i] = .{
            .step = item.object.get("step").?.string,
            .text = item.object.get("text").?.string,
        };
    }
    return out;
}

fn recordTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    prompt: []const u8,
    assistant: []const u8,
) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, prompt });
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"{s}"}}
    , .{ session_id, turn_id, sandbox.cwd, assistant });
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{"codex-hook"}, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{"codex-hook"}, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);
}

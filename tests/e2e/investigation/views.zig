const std = @import("std");
const golden = @import("../support/golden.zig");
const harness = @import("../support/harness.zig");

test "investigation/views show recent history without hash-first spelunking" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile("notes.txt", "alpha\nbeta\n");
    try sandbox.writeRepoFile("keep.txt", "same\n");
    try sandbox.writeRepoFile("deleted.txt", "remove me\n");

    try recordTurn(&sandbox, "investigation-sess", "turn-1", "Explain the initial repo snapshot", "first step complete");

    try sandbox.writeRepoFile("notes.txt", "alpha\ngamma\n");
    try sandbox.writeRepoFile("new.txt", "hello\n");
    try deleteRepoFile(&sandbox, "deleted.txt");

    try recordTurn(&sandbox, "investigation-sess", "turn-2", "Explain the follow-up repo changes", "second step complete");

    var status_result = try sandbox.run(&.{"status"}, null);
    defer status_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), status_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "Store path:") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "Sessions:        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "Steps:           2") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "Warnings:        none") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "Configured agents: (none)") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "Privacy display: full by default") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "Run `agit timeline`") != null);

    var timeline_result = try sandbox.run(&.{ "timeline", "--limit", "2" }, null);
    defer timeline_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), timeline_result.exit_code);
    const turn2_idx = std.mem.indexOf(u8, timeline_result.stdout, "turn turn-2") orelse return error.TestUnexpectedResult;
    const turn1_idx = std.mem.indexOf(u8, timeline_result.stdout, "turn turn-1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(turn2_idx < turn1_idx);
    try std.testing.expect(std.mem.indexOf(u8, timeline_result.stdout, "Explain the follow-up repo changes") != null);

    var log_result = try sandbox.run(&.{ "log", "--json", "codex/investigation-sess" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    const first_hash = try extractStepHashByTurn(log_result.stdout, "turn-1");
    defer std.testing.allocator.free(first_hash);
    const second_hash = try extractStepHashByTurn(log_result.stdout, "turn-2");
    defer std.testing.allocator.free(second_hash);

    var show_files = try sandbox.run(&.{ "show", "--files", second_hash }, null);
    defer show_files.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), show_files.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, show_files.stdout, "files:") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_files.stdout, "keep.txt (5 B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_files.stdout, "new.txt (6 B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_files.stdout, "notes.txt (12 B)") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_files.stdout, "deleted.txt") == null);

    var show_stat = try sandbox.run(&.{ "show", "--stat", second_hash }, null);
    defer show_stat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), show_stat.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "stat:") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "added     1") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "modified  1") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "deleted   1") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "unchanged 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "added    new.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "modified notes.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_stat.stdout, "deleted  deleted.txt") != null);

    var first_stat = try sandbox.run(&.{ "show", "--stat", first_hash }, null);
    defer first_stat.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), first_stat.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, first_stat.stdout, "added     3") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_stat.stdout, "modified  0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_stat.stdout, "deleted   0") != null);

    var diff_result = try sandbox.run(&.{ "diff", second_hash, "--", "notes.txt" }, null);
    defer diff_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), diff_result.exit_code);
    try golden.assertGolden(&sandbox, "tests/golden/investigation/diff_notes.txt", diff_result.stdout);
}

test "investigation/diff respects display-time redaction" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try sandbox.writeRepoFile(".agit/config.json",
        \\{
        \\  "version": 1,
        \\  "privacy": {
        \\    "display": { "redacted_by_default": true },
        \\    "custom_literals": ["super-secret"]
        \\  }
        \\}
    );
    try sandbox.writeRepoFile("secret.txt", "token=super-secret\n");
    try recordTurn(&sandbox, "redaction-sess", "turn-1", "Capture the secret file", "first capture complete");

    try sandbox.writeRepoFile("secret.txt", "token=super-secret\nstatus=updated\n");
    try recordTurn(&sandbox, "redaction-sess", "turn-2", "Capture the follow-up secret file", "second capture complete");

    var log_result = try sandbox.run(&.{ "log", "--json", "codex/redaction-sess" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    const second_hash = try extractStepHashByTurn(log_result.stdout, "turn-2");
    defer std.testing.allocator.free(second_hash);

    var redacted_diff = try sandbox.run(&.{ "diff", second_hash, "--", "secret.txt" }, null);
    defer redacted_diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), redacted_diff.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, redacted_diff.stdout, "super-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted_diff.stdout, "[REDACTED]") != null);

    var full_diff = try sandbox.run(&.{ "diff", "--full", second_hash, "--", "secret.txt" }, null);
    defer full_diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), full_diff.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, full_diff.stdout, "super-secret") != null);
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

fn deleteRepoFile(sandbox: *harness.Sandbox, rel_path: []const u8) !void {
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.cwd, rel_path });
    defer std.testing.allocator.free(abs_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, abs_path);
}

fn extractStepHashByTurn(data: []const u8, turn_id: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const steps = parsed.value.object.get("data").?.object.get("steps").?.array.items;
    for (steps) |step| {
        if (std.mem.eql(u8, step.object.get("turn_id").?.string, turn_id)) {
            return try std.testing.allocator.dupe(u8, step.object.get("hash").?.string);
        }
    }
    return error.StepNotFound;
}

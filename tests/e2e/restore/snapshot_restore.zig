const std = @import("std");
const harness = @import("../support/harness.zig");

test "restore/snapshot_restore restores deleted path from step snapshot" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const step_hash = try captureStepHash(&sandbox, "restore-deleted", "turn-1", &.{
        .{ .path = ".agit/.keep", .content = "" },
        .{ .path = "src/app.txt", .content = "captured\n" },
    });
    defer std.testing.allocator.free(step_hash);
    try deleteRepoFile(&sandbox, "src/app.txt");

    var result = try sandbox.run(&.{ "restore", step_hash, "--", "src/app.txt" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "restored src/app.txt") != null);
    try sandbox.expectFile("src/app.txt", "captured\n");
}

test "restore/snapshot_restore skips existing files unless forced" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const step_hash = try captureStepHash(&sandbox, "restore-force", "turn-1", &.{
        .{ .path = ".agit/.keep", .content = "" },
        .{ .path = "notes.txt", .content = "captured\n" },
    });
    defer std.testing.allocator.free(step_hash);
    try sandbox.writeRepoFile("notes.txt", "local\n");

    var skip_result = try sandbox.run(&.{ "restore", step_hash, "--", "notes.txt" }, null);
    defer skip_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), skip_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, skip_result.stdout, "skipped notes.txt") != null);
    try sandbox.expectFile("notes.txt", "local\n");

    var force_result = try sandbox.run(&.{ "restore", "--force", step_hash, "--", "notes.txt" }, null);
    defer force_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), force_result.exit_code);
    try sandbox.expectFile("notes.txt", "captured\n");
}

test "restore/snapshot_restore dry run does not write files" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const step_hash = try captureStepHash(&sandbox, "restore-dry-run", "turn-1", &.{
        .{ .path = ".agit/.keep", .content = "" },
        .{ .path = "dry.txt", .content = "captured\n" },
    });
    defer std.testing.allocator.free(step_hash);
    try deleteRepoFile(&sandbox, "dry.txt");

    var result = try sandbox.run(&.{ "restore", "--dry-run", step_hash, "--", "dry.txt" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "would restore dry.txt") != null);
    try expectRepoFileMissing(&sandbox, "dry.txt");
}

test "restore/snapshot_restore refuses implicit whole tree restore" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const step_hash = try captureStepHash(&sandbox, "restore-scope", "turn-1", &.{
        .{ .path = ".agit/.keep", .content = "" },
        .{ .path = "scope.txt", .content = "captured\n" },
    });
    defer std.testing.allocator.free(step_hash);

    var result = try sandbox.run(&.{ "restore", step_hash }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "requires --all") != null);
}

test "restore/snapshot_restore restores all captured files with all flag" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const step_hash = try captureStepHash(&sandbox, "restore-all", "turn-1", &.{
        .{ .path = ".agit/.keep", .content = "" },
        .{ .path = "one.txt", .content = "one\n" },
        .{ .path = "nested/two.txt", .content = "two\n" },
    });
    defer std.testing.allocator.free(step_hash);
    try deleteRepoFile(&sandbox, "one.txt");
    try deleteRepoFile(&sandbox, "nested/two.txt");

    var result = try sandbox.run(&.{ "restore", "--all", step_hash }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try sandbox.expectFile("one.txt", "one\n");
    try sandbox.expectFile("nested/two.txt", "two\n");
}

test "restore/snapshot_restore emits cli-json-v1 summary" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const step_hash = try captureStepHash(&sandbox, "restore-json", "turn-1", &.{
        .{ .path = ".agit/.keep", .content = "" },
        .{ .path = "json.txt", .content = "captured\n" },
    });
    defer std.testing.allocator.free(step_hash);
    try deleteRepoFile(&sandbox, "json.txt");

    var result = try sandbox.run(&.{ "restore", "--json", "--dry-run", step_hash, "--", "json.txt" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try parseJson(result.stdout);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("cli-json-v1", parsed.value.object.get("schema_version").?.string);
    try std.testing.expectEqualStrings("restore", parsed.value.object.get("command").?.string);
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 1), data.get("counts").?.object.get("restored").?.integer);
    try std.testing.expectEqualStrings("planned", data.get("items").?.array.items[0].object.get("status").?.string);
}

test "restore/snapshot_restore rejects escaping requested paths" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    const step_hash = try captureStepHash(&sandbox, "restore-unsafe", "turn-1", &.{
        .{ .path = ".agit/.keep", .content = "" },
        .{ .path = "safe.txt", .content = "safe\n" },
    });
    defer std.testing.allocator.free(step_hash);

    var result = try sandbox.run(&.{ "restore", step_hash, "--", "../outside.txt" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "safe workspace-relative path") != null);
}

const RepoFile = struct {
    path: []const u8,
    content: []const u8,
};

fn captureStepHash(sandbox: *harness.Sandbox, session_id: []const u8, turn_id: []const u8, files: []const RepoFile) ![]u8 {
    for (files) |file| {
        try sandbox.writeRepoFile(file.path, file.content);
    }
    try recordTurn(sandbox, session_id, turn_id);

    const session_arg = try std.fmt.allocPrint(std.testing.allocator, "codex/{s}", .{session_id});
    defer std.testing.allocator.free(session_arg);
    var log_result = try sandbox.run(&.{ "log", "--json", session_arg }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    return extractStepHashByTurn(log_result.stdout, turn_id);
}

fn recordTurn(sandbox: *harness.Sandbox, session_id: []const u8, turn_id: []const u8) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"restore test"}}
    , .{ session_id, turn_id, sandbox.cwd });
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","turn_id":"{s}","cwd":"{s}","hook_event_name":"Stop","last_assistant_message":"done"}}
    , .{ session_id, turn_id, sandbox.cwd });
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

fn expectRepoFileMissing(sandbox: *harness.Sandbox, rel_path: []const u8) !void {
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.cwd, rel_path });
    defer std.testing.allocator.free(abs_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, abs_path, .{}));
}

fn extractStepHashByTurn(data: []const u8, turn_id: []const u8) ![]u8 {
    var parsed = try parseJson(data);
    defer parsed.deinit();
    const steps = parsed.value.object.get("data").?.object.get("steps").?.array.items;
    for (steps) |step| {
        if (std.mem.eql(u8, step.object.get("turn_id").?.string, turn_id)) {
            return try std.testing.allocator.dupe(u8, step.object.get("hash").?.string);
        }
    }
    return error.StepNotFound;
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

const std = @import("std");
const harness = @import("support/harness.zig");

test "portable_bundle export and import round-trip, and repeated import is idempotent" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordClaudeSession(&sandbox, "bundle-roundtrip", "Write a changelog entry");

    const bundle_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bundle", .{sandbox.cwd});
    defer std.testing.allocator.free(bundle_path);

    var export_result = try sandbox.run(&.{ "export", "--json", bundle_path }, null);
    defer export_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), export_result.exit_code);
    try expectEnvelope(export_result.stdout, "export");

    try clearLocalStore(&sandbox);

    var import_result = try sandbox.run(&.{ "import", "--json", bundle_path }, null);
    defer import_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), import_result.exit_code);
    try expectEnvelope(import_result.stdout, "import");

    var log_result = try sandbox.run(&.{ "log", "--json", "claude/bundle-roundtrip" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
    const first_hash = try extractFirstStepHash(log_result.stdout);
    defer std.testing.allocator.free(first_hash);

    var second_import = try sandbox.run(&.{ "import", "--json", bundle_path }, null);
    defer second_import.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), second_import.exit_code);

    var parsed = try parseJson(second_import.stdout);
    defer parsed.deinit();
    const data = parsed.value.object.get("data").?.object;
    try std.testing.expectEqual(@as(i64, 0), data.get("imported_objects").?.integer);
    try std.testing.expect(data.get("skipped_objects").?.integer > 0);
    try std.testing.expectEqual(@as(i64, 1), data.get("unchanged_refs").?.integer);
}

test "portable_bundle import rejects corrupted objects before writing local data" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordClaudeSession(&sandbox, "bundle-corrupt", "Write a changelog entry");

    const bundle_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bundle", .{sandbox.cwd});
    defer std.testing.allocator.free(bundle_path);

    var export_result = try sandbox.run(&.{ "export", "--json", bundle_path }, null);
    defer export_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), export_result.exit_code);

    try clearLocalStore(&sandbox);
    try corruptFirstBundledObject(bundle_path);

    var import_result = try sandbox.run(&.{ "import", "--json", bundle_path }, null);
    defer import_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), import_result.exit_code);

    try std.testing.expectEqual(@as(usize, 0), try countLooseObjects(sandbox.cwd));

    var sessions_result = try sandbox.run(&.{ "sessions", "--json" }, null);
    defer sessions_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), sessions_result.exit_code);
    var parsed = try parseJson(sessions_result.stdout);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.object.get("data").?.object.get("sessions").?.array.items.len);
}

test "portable_bundle import namespaces conflicting refs by default" {
    var source = try harness.Sandbox.init(std.testing.allocator);
    defer source.deinit();
    var target = try harness.Sandbox.init(std.testing.allocator);
    defer target.deinit();

    try source.writeRepoFile(".agit/.keep", "");
    try target.writeRepoFile(".agit/.keep", "");
    try recordClaudeSession(&source, "shared-session", "bundle copy");
    try recordClaudeSession(&target, "shared-session", "local conflicting copy");

    const bundle_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bundle", .{source.cwd});
    defer std.testing.allocator.free(bundle_path);

    var export_result = try source.run(&.{ "export", "--json", bundle_path }, null);
    defer export_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), export_result.exit_code);

    var import_result = try target.run(&.{ "import", "--json", bundle_path }, null);
    defer import_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), import_result.exit_code);

    var sessions_result = try target.run(&.{ "sessions", "--json" }, null);
    defer sessions_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), sessions_result.exit_code);

    var parsed = try parseJson(sessions_result.stdout);
    defer parsed.deinit();
    const sessions = parsed.value.object.get("data").?.object.get("sessions").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), sessions.len);
    try std.testing.expect(findSessionId(sessions, "shared-session") != null);
    const imported_session = findImportSessionId(sessions, "shared-session") orelse return error.MissingNamespacedSession;
    try std.testing.expect(std.mem.startsWith(u8, imported_session, "shared-session@import-"));
}

test "portable_bundle export blocks sensitive plaintext bundles without override" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordClaudeSession(&sandbox, "bundle-secret", "Authorization: Bearer secret-token-123456");

    const bundle_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/bundle", .{sandbox.cwd});
    defer std.testing.allocator.free(bundle_path);

    var export_result = try sandbox.run(&.{ "export", "--json", bundle_path }, null);
    defer export_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), export_result.exit_code);
    try std.testing.expect(!pathExists(bundle_path));
}

fn recordClaudeSession(sandbox: *harness.Sandbox, session_id: []const u8, prompt: []const u8) !void {
    const user_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"UserPromptSubmit","prompt":"{s}"}}
    , .{ session_id, sandbox.cwd, prompt });
    defer std.testing.allocator.free(user_payload);
    const stop_payload = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"session_id":"{s}","transcript_path":"transcript.jsonl","cwd":"{s}","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}}
    , .{ session_id, sandbox.cwd });
    defer std.testing.allocator.free(stop_payload);

    var user_res = try sandbox.run(&.{ "claude-hook", "user" }, user_payload);
    defer user_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), user_res.exit_code);

    var stop_res = try sandbox.run(&.{ "claude-hook", "assistant" }, stop_payload);
    defer stop_res.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stop_res.exit_code);
}

fn clearLocalStore(sandbox: *harness.Sandbox) !void {
    try deleteTreeIfExists(sandbox, ".agit/objects");
    try deleteTreeIfExists(sandbox, ".agit/refs");
    try deleteTreeIfExists(sandbox, ".agit/tmp");
    try deleteTreeIfExists(sandbox, ".agit/log");
    try deleteFileIfExists(sandbox, ".agit/index.db");
    try deleteFileIfExists(sandbox, ".agit/index.db-wal");
    try deleteFileIfExists(sandbox, ".agit/index.db-shm");
    try sandbox.writeRepoFile(".agit/.keep", "");
}

fn deleteTreeIfExists(sandbox: *harness.Sandbox, rel_path: []const u8) !void {
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.cwd, rel_path });
    defer std.testing.allocator.free(abs_path);
    _ = std.Io.Dir.cwd().statFile(std.testing.io, abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try std.Io.Dir.cwd().deleteTree(std.testing.io, abs_path);
}

fn deleteFileIfExists(sandbox: *harness.Sandbox, rel_path: []const u8) !void {
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ sandbox.cwd, rel_path });
    defer std.testing.allocator.free(abs_path);
    _ = std.Io.Dir.cwd().statFile(std.testing.io, abs_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try std.Io.Dir.cwd().deleteFile(std.testing.io, abs_path);
}

fn corruptFirstBundledObject(bundle_path: []const u8) !void {
    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/manifest.json", .{bundle_path});
    defer std.testing.allocator.free(manifest_path);
    const manifest_raw = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, manifest_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(manifest_raw);

    var parsed = try parseJson(manifest_raw);
    defer parsed.deinit();
    const objects = parsed.value.object.get("objects").?.array.items;
    const rel_path = objects[0].object.get("path").?.string;
    const object_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ bundle_path, rel_path });
    defer std.testing.allocator.free(object_path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, object_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "corrupt-object");
}

fn countLooseObjects(repo_path: []const u8) !usize {
    const objects_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.agit/objects", .{repo_path});
    defer std.testing.allocator.free(objects_path);
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, objects_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return 0,
        else => return err,
    };
    defer dir.close(std.testing.io);

    var count: usize = 0;
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, "pack/")) continue;
        count += 1;
    }
    return count;
}

fn pathExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var dir = std.Io.Dir.cwd().openDir(std.testing.io, path, .{}) catch return false;
            dir.close(std.testing.io);
            return true;
        },
        else => return false,
    };
    return true;
}

fn extractFirstStepHash(data: []const u8) ![]u8 {
    var parsed = try parseJson(data);
    defer parsed.deinit();
    const steps = parsed.value.object.get("data").?.object.get("steps").?.array.items;
    return try std.testing.allocator.dupe(u8, steps[0].object.get("hash").?.string);
}

fn findSessionId(items: []const std.json.Value, session_id: []const u8) ?[]const u8 {
    for (items) |item| {
        const current = item.object.get("session_id").?.string;
        if (std.mem.eql(u8, current, session_id)) return current;
    }
    return null;
}

fn findImportSessionId(items: []const std.json.Value, prefix: []const u8) ?[]const u8 {
    for (items) |item| {
        const current = item.object.get("session_id").?.string;
        if (std.mem.startsWith(u8, current, prefix) and std.mem.indexOf(u8, current, "@import-") != null) return current;
    }
    return null;
}

fn parseJson(data: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, data, .{
        .allocate = .alloc_always,
    });
}

fn expectEnvelope(data: []const u8, command: []const u8) !void {
    var parsed = try parseJson(data);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("cli-json-v1", parsed.value.object.get("schema_version").?.string);
    try std.testing.expectEqualStrings(command, parsed.value.object.get("command").?.string);
}

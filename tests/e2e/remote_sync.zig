const std = @import("std");
const fake_s3 = @import("support/fake_s3.zig");
const harness = @import("support/harness.zig");

test "remote_sync push and pull round-trip store history" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var remote = try fake_s3.Server.start(std.testing.allocator, std.testing.io, sandbox.root);
    defer remote.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try writeRemoteConfig(&sandbox, remote.endpoint, false);
    try recordSession(&sandbox, "roundtrip-sess", "Write a changelog entry");

    var push_result = try sandbox.runWithEnv(&.{ "push", "--json" }, null, remoteEnv(false));
    defer push_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), push_result.exit_code);
    try expectEnvelope(push_result.stdout, "push");

    try clearLocalStoreButKeepConfig(&sandbox);

    var pull_result = try sandbox.runWithEnv(&.{ "pull", "--json" }, null, remoteEnv(false));
    defer pull_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), pull_result.exit_code);
    try expectEnvelope(pull_result.stdout, "pull");

    var log_result = try sandbox.run(&.{ "log", "--json", "claude/roundtrip-sess" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);

    var parsed = try parseJson(log_result.stdout);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("data").?.object.get("steps").?.array.items.len);
}

test "remote_sync push blocks sensitive plaintext uploads unless overridden" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var remote = try fake_s3.Server.start(std.testing.allocator, std.testing.io, sandbox.root);
    defer remote.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try writeRemoteConfig(&sandbox, remote.endpoint, false);
    try recordSession(&sandbox, "privacy-sess", "Authorization: Bearer secret-token-123456");

    var push_result = try sandbox.runWithEnv(&.{"push"}, null, remoteEnv(false));
    defer push_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), push_result.exit_code);
    try std.testing.expect(
        std.mem.indexOf(u8, push_result.stdout, "sensitive plaintext") != null or
            std.mem.indexOf(u8, push_result.stderr, "sensitive plaintext") != null,
    );
}

test "remote_sync encrypted push stores unreadable objects and pull restores them" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var remote = try fake_s3.Server.start(std.testing.allocator, std.testing.io, sandbox.root);
    defer remote.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try writeRemoteConfig(&sandbox, remote.endpoint, true);
    try recordSession(&sandbox, "encrypted-sess", "Authorization: Bearer secret-token-123456");

    var push_result = try sandbox.runWithEnv(&.{ "push", "--json" }, null, remoteEnv(true));
    defer push_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), push_result.exit_code);

    const stored = try readAnyStoredObject(&remote);
    defer std.testing.allocator.free(stored);
    try std.testing.expect(std.mem.indexOf(u8, stored, "secret-token-123456") == null);

    try clearLocalStoreButKeepConfig(&sandbox);

    var pull_result = try sandbox.runWithEnv(&.{ "pull", "--json" }, null, remoteEnv(true));
    defer pull_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), pull_result.exit_code);

    var log_result = try sandbox.run(&.{ "log", "--json", "claude/encrypted-sess" }, null);
    defer log_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), log_result.exit_code);
}

test "remote_sync push blocks when encryption secret env var is present but empty" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    var remote = try fake_s3.Server.start(std.testing.allocator, std.testing.io, sandbox.root);
    defer remote.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try writeRemoteConfig(&sandbox, remote.endpoint, true);
    try recordSession(&sandbox, "empty-secret-sess", "Authorization: Bearer secret-token-123456");

    var push_result = try sandbox.runWithEnv(&.{"push"}, null, remoteEnvEmptySecret());
    defer push_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), push_result.exit_code);
    try std.testing.expect(
        std.mem.indexOf(u8, push_result.stdout, "sensitive plaintext") != null or
            std.mem.indexOf(u8, push_result.stderr, "sensitive plaintext") != null,
    );
}

test "remote_sync rejects insecure non-local HTTP endpoints before upload" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try writeRemoteConfig(&sandbox, "http://example.com", false);
    try recordSession(&sandbox, "http-remote-sess", "Write docs");

    var push_result = try sandbox.runWithEnv(&.{ "push", "--json" }, null, remoteEnv(false));
    defer push_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), push_result.exit_code);
    try std.testing.expect(
        std.mem.indexOf(u8, push_result.stdout, "InsecureRemoteEndpoint") != null or
            std.mem.indexOf(u8, push_result.stderr, "InsecureRemoteEndpoint") != null,
    );
}

fn writeRemoteConfig(sandbox: *harness.Sandbox, endpoint: []const u8, encrypted: bool) !void {
    const config = if (encrypted)
        try std.fmt.allocPrint(std.testing.allocator,
            \\{{
            \\  "version": 1,
            \\  "remotes": [
            \\    {{
            \\      "name": "backup",
            \\      "endpoint": "{s}",
            \\      "bucket": "agit-test",
            \\      "region": "us-east-1",
            \\      "access_key_env": "AGIT_S3_ACCESS_KEY",
            \\      "secret_key_env": "AGIT_S3_SECRET_KEY",
            \\      "encryption_secret_env": "AGIT_S3_ENCRYPTION_SECRET"
            \\    }}
            \\  ]
            \\}}
        , .{endpoint})
    else
        try std.fmt.allocPrint(std.testing.allocator,
            \\{{
            \\  "version": 1,
            \\  "remotes": [
            \\    {{
            \\      "name": "backup",
            \\      "endpoint": "{s}",
            \\      "bucket": "agit-test",
            \\      "region": "us-east-1",
            \\      "access_key_env": "AGIT_S3_ACCESS_KEY",
            \\      "secret_key_env": "AGIT_S3_SECRET_KEY"
            \\    }}
            \\  ]
            \\}}
        , .{endpoint});
    defer std.testing.allocator.free(config);
    try sandbox.writeRepoFile(".agit/config.json", config);
}

fn recordSession(sandbox: *harness.Sandbox, session_id: []const u8, prompt: []const u8) !void {
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

fn clearLocalStoreButKeepConfig(sandbox: *harness.Sandbox) !void {
    try deleteTreeIfExists(sandbox, ".agit/objects");
    try deleteTreeIfExists(sandbox, ".agit/refs");
    try deleteTreeIfExists(sandbox, ".agit/tmp");
    try deleteTreeIfExists(sandbox, ".agit/log");
    try deleteFileIfExists(sandbox, ".agit/index.db");
    try deleteFileIfExists(sandbox, ".agit/index.db-wal");
    try deleteFileIfExists(sandbox, ".agit/index.db-shm");
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

fn readAnyStoredObject(remote: *fake_s3.Server) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, remote.storage_root, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        return try dir.readFileAlloc(std.testing.io, entry.path, std.testing.allocator, .unlimited);
    }
    return error.FileNotFound;
}

fn remoteEnv(comptime encrypted: bool) []const []const u8 {
    return if (encrypted)
        &.{
            "AGIT_S3_ACCESS_KEY=test-access",
            "AGIT_S3_SECRET_KEY=test-secret",
            "AGIT_S3_ENCRYPTION_SECRET=test-encryption-secret",
        }
    else
        &.{
            "AGIT_S3_ACCESS_KEY=test-access",
            "AGIT_S3_SECRET_KEY=test-secret",
        };
}

fn remoteEnvEmptySecret() []const []const u8 {
    return &.{
        "AGIT_S3_ACCESS_KEY=test-access",
        "AGIT_S3_SECRET_KEY=test-secret",
        "AGIT_S3_ENCRYPTION_SECRET=",
    };
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

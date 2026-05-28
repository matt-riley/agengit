const std = @import("std");

pub const CaptureLevel = enum {
    full,
    redacted,
    metadata_only,
    disabled,
};

pub const CaptureConfig = struct {
    prompts: CaptureLevel = .full,
    assistant: CaptureLevel = .full,
    tool_args: CaptureLevel = .full,
    tool_results: CaptureLevel = .full,
    snapshots: CaptureLevel = .full,
};

pub const DisplayConfig = struct {
    redacted_by_default: bool = false,
};

pub const RemoteBackend = enum {
    s3,
};

pub const RemoteConfig = struct {
    name: []const u8,
    backend: RemoteBackend = .s3,
    endpoint: []const u8,
    bucket: []const u8,
    region: []const u8 = "us-east-1",
    prefix: []const u8 = "",
    access_key_env: []const u8,
    secret_key_env: []const u8,
    session_token_env: ?[]const u8 = null,
    encryption_secret_env: ?[]const u8 = null,
};

pub const PrivacyConfig = struct {
    enabled_origins: []const []const u8 = &.{},
    capture: CaptureConfig = .{},
    display: DisplayConfig = .{},
    custom_literals: []const []const u8 = &.{},

    pub fn originEnabled(self: PrivacyConfig, origin: []const u8) bool {
        if (self.enabled_origins.len == 0) return true;
        for (self.enabled_origins) |allowed| {
            if (std.mem.eql(u8, allowed, origin)) return true;
        }
        return false;
    }
};

pub const File = struct {
    version: u32 = 1,
    privacy: PrivacyConfig = .{},
    remotes: []const RemoteConfig = &.{},
};

pub const Loaded = struct {
    parsed: ?std.json.Parsed(File) = null,
    value: File = .{},

    pub fn deinit(self: *Loaded) void {
        if (self.parsed) |*parsed| parsed.deinit();
        self.* = undefined;
    }

    pub fn default() Loaded {
        return .{};
    }

    pub fn failClosedCapture() Loaded {
        return .{
            .value = .{
                .privacy = .{
                    .capture = .{
                        .prompts = .disabled,
                        .assistant = .disabled,
                        .tool_args = .disabled,
                        .tool_results = .disabled,
                        .snapshots = .disabled,
                    },
                    .display = .{ .redacted_by_default = true },
                },
            },
        };
    }
};

pub fn loadFromStore(io: std.Io, store_root: std.Io.Dir, gpa: std.mem.Allocator) !Loaded {
    const data = store_root.readFileAlloc(io, "config.json", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return Loaded.default(),
        else => return err,
    };
    defer gpa.free(data);

    var parsed = try std.json.parseFromSlice(File, gpa, data, .{
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    if (parsed.value.version != 1) return error.UnsupportedConfigVersion;
    return .{
        .parsed = parsed,
        .value = parsed.value,
    };
}

pub fn loadOrDefaultFromStore(io: std.Io, store_root: std.Io.Dir, gpa: std.mem.Allocator) !Loaded {
    return loadFromStore(io, store_root, gpa);
}

pub fn selectRemote(file: File, name: ?[]const u8) !RemoteConfig {
    if (file.remotes.len == 0) return error.RemoteNotConfigured;

    if (name) |target_name| {
        var match: ?RemoteConfig = null;
        for (file.remotes) |remote| {
            if (!std.mem.eql(u8, remote.name, target_name)) continue;
            if (match != null) return error.DuplicateRemoteName;
            match = remote;
        }
        return match orelse error.RemoteNotFound;
    }

    if (file.remotes.len == 1) return file.remotes[0];
    return error.RemoteSelectionRequired;
}

test "loadFromStore defaults when config is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var loaded = try loadFromStore(std.testing.io, tmp.dir, std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expect(loaded.value.privacy.originEnabled("claude"));
    try std.testing.expect(!loaded.value.privacy.display.redacted_by_default);
}

test "loadFromStore parses privacy config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".agit");
    var agit = try tmp.dir.openDir(std.testing.io, ".agit", .{});
    defer agit.close(std.testing.io);
    var file = try agit.createFile(std.testing.io, "config.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{
        \\  "version": 1,
        \\  "privacy": {
        \\    "enabled_origins": ["codex"],
        \\    "capture": { "tool_results": "metadata_only" },
        \\    "display": { "redacted_by_default": true },
        \\    "custom_literals": ["customer-secret"]
        \\  }
        \\}
    );

    var loaded = try loadFromStore(std.testing.io, agit, std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expect(!loaded.value.privacy.originEnabled("claude"));
    try std.testing.expect(loaded.value.privacy.originEnabled("codex"));
    try std.testing.expect(loaded.value.privacy.capture.tool_results == .metadata_only);
    try std.testing.expect(loaded.value.privacy.display.redacted_by_default);
    try std.testing.expectEqual(@as(usize, 1), loaded.value.privacy.custom_literals.len);
}

test "loadFromStore parses remotes config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".agit");
    var agit = try tmp.dir.openDir(std.testing.io, ".agit", .{});
    defer agit.close(std.testing.io);
    var file = try agit.createFile(std.testing.io, "config.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io,
        \\{
        \\  "version": 1,
        \\  "remotes": [
        \\    {
        \\      "name": "backup",
        \\      "endpoint": "http://127.0.0.1:9000",
        \\      "bucket": "agit-backups",
        \\      "region": "us-east-1",
        \\      "prefix": "prod",
        \\      "access_key_env": "AGIT_REMOTE_ACCESS_KEY",
        \\      "secret_key_env": "AGIT_REMOTE_SECRET_KEY",
        \\      "session_token_env": "AGIT_REMOTE_SESSION_TOKEN",
        \\      "encryption_secret_env": "AGIT_REMOTE_ENCRYPTION_SECRET"
        \\    }
        \\  ]
        \\}
    );

    var loaded = try loadFromStore(std.testing.io, agit, std.testing.allocator);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.value.remotes.len);
    try std.testing.expectEqualStrings("backup", loaded.value.remotes[0].name);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000", loaded.value.remotes[0].endpoint);
    try std.testing.expectEqualStrings("agit-backups", loaded.value.remotes[0].bucket);
    try std.testing.expectEqualStrings("AGIT_REMOTE_ENCRYPTION_SECRET", loaded.value.remotes[0].encryption_secret_env.?);
}

test "selectRemote resolves explicit and implicit remotes" {
    const file = File{
        .remotes = &[_]RemoteConfig{
            .{
                .name = "backup",
                .endpoint = "http://127.0.0.1:9000",
                .bucket = "agit",
                .access_key_env = "AK",
                .secret_key_env = "SK",
            },
            .{
                .name = "secondary",
                .endpoint = "http://127.0.0.1:9001",
                .bucket = "agit-2",
                .access_key_env = "AK2",
                .secret_key_env = "SK2",
            },
        },
    };

    try std.testing.expectError(error.RemoteSelectionRequired, selectRemote(file, null));
    const selected = try selectRemote(file, "secondary");
    try std.testing.expectEqualStrings("secondary", selected.name);
    try std.testing.expectError(error.RemoteNotFound, selectRemote(file, "missing"));

    const single = File{
        .remotes = &[_]RemoteConfig{
            .{
                .name = "only",
                .endpoint = "http://127.0.0.1:9000",
                .bucket = "agit",
                .access_key_env = "AK",
                .secret_key_env = "SK",
            },
        },
    };
    try std.testing.expectEqualStrings("only", (try selectRemote(single, null)).name);
}

test "loadOrDefaultFromStore reports malformed config errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, ".agit");
    var agit = try tmp.dir.openDir(std.testing.io, ".agit", .{});
    defer agit.close(std.testing.io);
    var file = try agit.createFile(std.testing.io, "config.json", .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, "{not-json");

    _ = loadOrDefaultFromStore(std.testing.io, agit, std.testing.allocator) catch return;
    return error.TestExpectedError;
}

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

pub fn loadOrDefaultFromStore(io: std.Io, store_root: std.Io.Dir, gpa: std.mem.Allocator) Loaded {
    return loadFromStore(io, store_root, gpa) catch Loaded.default();
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

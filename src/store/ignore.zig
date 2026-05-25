const std = @import("std");

/// Default directory names that are always excluded from snapshots.
const default_ignore_dirs = [_][]const u8{
    ".git",      ".agit",      "node_modules", "target", ".venv",
    "dist",      "build",      ".cache",       "vendor", "__pycache__",
    "zig-cache", ".zig-cache", "zig-out",
};

/// Default filenames that are always excluded (secrets / credentials).
const default_ignore_exact = [_][]const u8{
    ".env",
    "id_rsa",
    "id_ecdsa",
    "id_ed25519",
    "id_dsa",
    "id_ecdsa_sk",
    "id_ed25519_sk",
};

/// Default filename suffixes that are always excluded.
const default_ignore_suffixes = [_][]const u8{
    ".key", ".pem", ".p12", ".p8", ".pfx", ".crt", ".cer", ".csr",
};

/// Default filename prefixes that are always excluded.
const default_ignore_prefixes = [_][]const u8{
    ".env.",
};

/// Decides which workspace paths should be excluded from a snapshot.
///
/// Patterns from `.agitignore` support three forms:
///   - exact match:   `Makefile`
///   - prefix match:  `build_*`  (trailing `*`)
///   - suffix match:  `*.log`    (leading `*`)
pub const Ignorer = struct {
    /// Extra patterns loaded from `.agitignore` (each is an owned slice).
    custom_lines: [][]u8,
    gpa: std.mem.Allocator,
    /// True when `custom_lines` was heap-allocated by `fromDir` and must be freed.
    heap_owned: bool,

    /// Default ignorer with no custom patterns.
    pub fn initDefault(gpa: std.mem.Allocator) Ignorer {
        return .{ .custom_lines = &.{}, .gpa = gpa, .heap_owned = false };
    }

    /// Load patterns from `dir/.agitignore`, falling back to `initDefault` when
    /// the file does not exist.  Blank lines and lines starting with `#` are
    /// skipped.  Trailing `/` is stripped (treated as directory-only hint).
    pub fn fromDir(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator) !Ignorer {
        const data = dir.readFileAlloc(io, ".agitignore", gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return initDefault(gpa),
            else => return err,
        };
        defer gpa.free(data);

        var lines: std.ArrayList([]u8) = .empty;
        errdefer {
            for (lines.items) |l| gpa.free(l);
            lines.deinit(gpa);
        }

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \r\t"), "/");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            try lines.append(gpa, try gpa.dupe(u8, trimmed));
        }

        const owned = try lines.toOwnedSlice(gpa);
        if (owned.len == 0) {
            gpa.free(owned);
            return initDefault(gpa);
        }
        return .{ .custom_lines = owned, .gpa = gpa, .heap_owned = true };
    }

    pub fn deinit(self: *Ignorer) void {
        if (self.heap_owned) {
            for (self.custom_lines) |l| self.gpa.free(l);
            self.gpa.free(self.custom_lines);
        }
        self.* = undefined;
    }

    /// Returns true if a directory with this name should not be entered.
    pub fn shouldIgnoreDir(self: *const Ignorer, name: []const u8) bool {
        for (default_ignore_dirs) |d| {
            if (std.mem.eql(u8, name, d)) return true;
        }
        for (self.custom_lines) |p| {
            if (matchesSimplePattern(p, name)) return true;
        }
        return false;
    }

    /// Returns true if a file with this basename should be excluded.
    pub fn shouldIgnoreFile(self: *const Ignorer, name: []const u8) bool {
        for (default_ignore_exact) |e| {
            if (std.mem.eql(u8, name, e)) return true;
        }
        for (default_ignore_suffixes) |s| {
            if (std.mem.endsWith(u8, name, s)) return true;
        }
        for (default_ignore_prefixes) |p| {
            if (std.mem.startsWith(u8, name, p)) return true;
        }
        for (self.custom_lines) |p| {
            if (matchesSimplePattern(p, name)) return true;
        }
        return false;
    }

    /// Returns true if this workspace-relative path should be excluded.
    ///
    /// Checks every directory component with `shouldIgnoreDir`, then the
    /// filename with `shouldIgnoreFile`.
    pub fn shouldIgnorePath(self: *const Ignorer, rel_path: []const u8) bool {
        var rest = rel_path;
        while (std.mem.indexOfScalar(u8, rest, '/')) |sep| {
            const component = rest[0..sep];
            if (self.shouldIgnoreDir(component)) return true;
            rest = rest[sep + 1 ..];
        }
        return self.shouldIgnoreFile(rest);
    }
};

/// Simple single-`*` glob used for `.agitignore` patterns.
///   - No `*`  → exact match
///   - Leading `*` → suffix match (`*.log` matches `foo.log`)
///   - Trailing `*` → prefix match (`build_*` matches `build_x`)
fn matchesSimplePattern(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '*')) |star| {
        if (star == 0) {
            return std.mem.endsWith(u8, name, pattern[1..]);
        } else if (star == pattern.len - 1) {
            return std.mem.startsWith(u8, name, pattern[0..star]);
        }
        return false; // mid-pattern `*` unsupported
    }
    return std.mem.eql(u8, pattern, name);
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "initDefault ignores standard dirs and secrets" {
    const ig = Ignorer.initDefault(std.testing.allocator);

    try std.testing.expect(ig.shouldIgnoreDir(".agit"));
    try std.testing.expect(ig.shouldIgnoreDir("node_modules"));
    try std.testing.expect(ig.shouldIgnoreDir(".git"));
    try std.testing.expect(!ig.shouldIgnoreDir("src"));

    try std.testing.expect(ig.shouldIgnoreFile(".env"));
    try std.testing.expect(ig.shouldIgnoreFile("id_rsa"));
    try std.testing.expect(ig.shouldIgnoreFile("server.pem"));
    try std.testing.expect(ig.shouldIgnoreFile(".env.local"));
    try std.testing.expect(!ig.shouldIgnoreFile("main.zig"));
}

test "shouldIgnorePath propagates dir check" {
    const ig = Ignorer.initDefault(std.testing.allocator);
    try std.testing.expect(ig.shouldIgnorePath("node_modules/lodash/index.js"));
    try std.testing.expect(ig.shouldIgnorePath("src/id_rsa"));
    try std.testing.expect(!ig.shouldIgnorePath("src/main.zig"));
}

test "fromDir loads custom patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const content = "# comment\n\n*.log\nbuild_*\nexact\n";
    var f = try tmp.dir.createFile(io, ".agitignore", .{});
    try f.writeStreamingAll(io, content);
    f.close(io);

    var ig = try Ignorer.fromDir(io, tmp.dir, std.testing.allocator);
    defer ig.deinit();

    try std.testing.expect(ig.shouldIgnoreFile("app.log"));
    try std.testing.expect(ig.shouldIgnoreFile("build_release"));
    try std.testing.expect(ig.shouldIgnoreFile("exact"));
    try std.testing.expect(!ig.shouldIgnoreFile("main.zig"));
}

test "fromDir falls back when no .agitignore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var ig = try Ignorer.fromDir(io, tmp.dir, std.testing.allocator);
    defer ig.deinit();

    try std.testing.expect(!ig.heap_owned);
    try std.testing.expect(ig.shouldIgnoreDir(".git"));
}

const std = @import("std");
const config_mod = @import("../store/config.zig");
const store_mod = @import("../store/store.zig");
const output_mod = @import("output.zig");
const status = @import("status.zig");

pub const RedactionMode = enum {
    auto,
    redacted,
    full,
};

pub const SessionFilter = struct {
    origin: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub fn shouldUseRedaction(mode: RedactionMode, redacted_by_default: bool) bool {
    return switch (mode) {
        .auto => redacted_by_default,
        .redacted => true,
        .full => false,
    };
}

pub const QuerySetup = struct {
    config: config_mod.Loaded,
    use_redaction: bool,

    pub fn deinit(self: *QuerySetup) void {
        self.config.deinit();
    }
};

pub fn loadQuerySetup(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *const store_mod.Store,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    command_name: []const u8,
    redaction_mode: RedactionMode,
) !QuerySetup {
    const loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
        try status.writeDiagnostic(stdout, format, command_name, .{
            .code = "invalid_config",
            .message = "Failed to load .agit/config.json.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        });
        try stdout.flush();
        std.process.exit(1);
    };
    const use_redaction = shouldUseRedaction(redaction_mode, loaded_config.value.privacy.display.redacted_by_default);
    return .{ .config = loaded_config, .use_redaction = use_redaction };
}

pub fn resolveSessionFilter(
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    command_name: []const u8,
    origin: ?[]const u8,
    session: ?[]const u8,
) !SessionFilter {
    var filter: SessionFilter = .{ .origin = origin };
    if (session) |value| {
        if (std.mem.indexOfScalar(u8, value, '/')) |sep| {
            const qualified_origin = value[0..sep];
            if (filter.origin) |expected_origin| {
                if (!std.mem.eql(u8, expected_origin, qualified_origin)) {
                    try status.writeDiagnostic(stdout, format, command_name, .{
                        .code = "invalid_argument",
                        .message = "--origin does not match the origin prefix embedded in --session.",
                    });
                    try stdout.flush();
                    return error.InvalidArgument;
                }
            }
            filter.origin = qualified_origin;
            filter.session_id = value[sep + 1 ..];
        } else {
            filter.session_id = value;
        }
    }
    return filter;
}

pub fn buildMatchQuery(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (count > 0) try out.appendSlice(gpa, " AND ");
        try appendQuotedToken(&out, gpa, token);
        count += 1;
    }

    if (count == 0) return error.InvalidArgument;
    return out.toOwnedSlice(gpa);
}

pub fn appendQuotedToken(out: *std.ArrayList(u8), gpa: std.mem.Allocator, token: []const u8) !void {
    try out.append(gpa, '"');
    for (token) |byte| {
        if (byte == '"') {
            try out.append(gpa, '"');
            try out.append(gpa, '"');
        } else {
            try out.append(gpa, byte);
        }
    }
    try out.append(gpa, '"');
}

test "buildMatchQuery: single token becomes quoted" {
    const gpa = std.testing.allocator;
    const result = try buildMatchQuery(gpa, "hello");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "buildMatchQuery: multiple tokens joined with AND" {
    const gpa = std.testing.allocator;
    const result = try buildMatchQuery(gpa, "hello world");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"hello\" AND \"world\"", result);
}

test "buildMatchQuery: empty string returns InvalidArgument" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, buildMatchQuery(gpa, ""));
}

test "appendQuotedToken: escapes embedded quotes" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendQuotedToken(&out, gpa, "a\"b");
    const result = try out.toOwnedSlice(gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"a\"\"b\"", result);
}

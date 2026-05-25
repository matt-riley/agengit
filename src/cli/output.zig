const std = @import("std");

pub const schema_version = "cli-json-v1";

pub const Format = enum {
    human,
    json,
};

pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    hint: ?[]const u8 = null,
    path: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

pub const CheckStatus = enum {
    ok,
    info,
    warn,
    @"error",
};

pub const Check = struct {
    code: []const u8,
    status: CheckStatus,
    message: []const u8,
    hint: ?[]const u8 = null,
    path: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

pub fn writeEnvelope(w: anytype, command: []const u8, data: anytype) !void {
    var mutable_w = w;
    const payload = .{
        .schema_version = schema_version,
        .command = command,
        .data = data,
    };
    if (@hasField(@TypeOf(mutable_w.*), "interface")) {
        try std.json.Stringify.value(payload, .{}, &mutable_w.interface);
        try mutable_w.interface.writeAll("\n");
    } else {
        try std.json.Stringify.value(payload, .{}, mutable_w);
        try mutable_w.writeAll("\n");
    }
}

pub fn writeDiagnosticEnvelope(w: anytype, command: []const u8, diagnostic: Diagnostic) !void {
    try writeEnvelope(w, command, .{ .diagnostic = diagnostic });
}

test "writeEnvelope includes schema version command and data" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeEnvelope(&aw.writer, "status", .{ .sessions = @as(i64, 2), .steps = @as(i64, 5) });

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.writer.buffered(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings(schema_version, root.get("schema_version").?.string);
    try std.testing.expectEqualStrings("status", root.get("command").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("data").?.object.get("sessions").?.integer);
    try std.testing.expectEqual(@as(i64, 5), root.get("data").?.object.get("steps").?.integer);
}

test "writeDiagnosticEnvelope encodes diagnostic details" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try writeDiagnosticEnvelope(&aw.writer, "show", .{
        .code = "object_not_found",
        .message = "Object not found.",
        .hint = "Use a longer hash prefix.",
        .hash = "abc123",
    });

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.writer.buffered(), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const diagnostic = parsed.value.object.get("data").?.object.get("diagnostic").?.object;
    try std.testing.expectEqualStrings("object_not_found", diagnostic.get("code").?.string);
    try std.testing.expectEqualStrings("Object not found.", diagnostic.get("message").?.string);
    try std.testing.expectEqualStrings("Use a longer hash prefix.", diagnostic.get("hint").?.string);
    try std.testing.expectEqualStrings("abc123", diagnostic.get("hash").?.string);
}

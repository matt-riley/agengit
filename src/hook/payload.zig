const std = @import("std");
const adapter_mod = @import("Adapter.zig");

pub fn stringifyValue(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{});
}

pub fn stringOrJson(gpa: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| try gpa.dupe(u8, s),
        else => try stringifyValue(gpa, value),
    };
}

pub fn toolUseFromValue(gpa: std.mem.Allocator, value: std.json.Value, non_object_reason: []const u8) !adapter_mod.ToolUse {
    return switch (value) {
        .object => |root| toolUseFromObject(gpa, root, value),
        else => .{
            .tool_name = "unknown",
            .args = try stringifyValue(gpa, value),
            .result = non_object_reason,
        },
    };
}

pub fn toolUseFromObject(gpa: std.mem.Allocator, root: std.json.ObjectMap, raw: std.json.Value) !adapter_mod.ToolUse {
    const maybe_tool_name = root.get("tool_name");
    const malformed_reason: ?[]const u8 = if (maybe_tool_name) |value| switch (value) {
        .string => null,
        else => "invalid tool_name",
    } else "missing tool_name";
    const tool_name = if (maybe_tool_name) |value| switch (value) {
        .string => |s| s,
        else => "unknown",
    } else "unknown";

    if (malformed_reason) |reason| {
        return .{
            .tool_name = tool_name,
            .args = try stringifyValue(gpa, raw),
            .result = reason,
        };
    }

    const tool_input_val = root.get("tool_input") orelse std.json.Value.null;
    const tool_response_val = root.get("tool_response") orelse std.json.Value.null;
    return .{
        .tool_name = tool_name,
        .args = try stringifyValue(gpa, tool_input_val),
        .result = try stringOrJson(gpa, tool_response_val),
    };
}

test "toolUseFromValue records malformed non-object tools" {
    const gpa = std.testing.allocator;
    const value = std.json.Value{ .string = "oops" };
    const tool = try toolUseFromValue(gpa, value, "tool entry is not an object");
    defer gpa.free(tool.args);
    try std.testing.expectEqualStrings("unknown", tool.tool_name);
    try std.testing.expectEqualStrings("\"oops\"", tool.args);
    try std.testing.expectEqualStrings("tool entry is not an object", tool.result);
}

test "toolUseFromObject keeps malformed tool payloads observable" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"tool_input":{"command":"true"}}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const tool = try toolUseFromObject(gpa, parsed.value.object, parsed.value);
    defer gpa.free(tool.args);
    try std.testing.expectEqualStrings("unknown", tool.tool_name);
    try std.testing.expectEqualStrings("missing tool_name", tool.result);
}

test "toolUseFromObject allocates string tool results" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"tool_name":"bash","tool_input":{"command":"true"},"tool_response":"ok"}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const tool = try toolUseFromObject(gpa, parsed.value.object, parsed.value);
    defer gpa.free(tool.args);
    defer gpa.free(tool.result);
    try std.testing.expectEqualStrings("bash", tool.tool_name);
    try std.testing.expectEqualStrings("ok", tool.result);
}

test "toolUseFromObject allocates json tool results" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"tool_name":"bash","tool_input":{"command":"true"},"tool_response":{"status":"ok"}}
    , .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const tool = try toolUseFromObject(gpa, parsed.value.object, parsed.value);
    defer gpa.free(tool.args);
    defer gpa.free(tool.result);
    try std.testing.expectEqualStrings("bash", tool.tool_name);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", tool.result);
}

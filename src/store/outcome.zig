const std = @import("std");
const object = @import("object.zig");

pub const Outcome = enum {
    success,
    failure,
    unknown,

    pub fn label(self: Outcome) []const u8 {
        return switch (self) {
            .success => "success",
            .failure => "failure",
            .unknown => "unknown",
        };
    }
};

pub fn parseLabel(label: ?[]const u8) Outcome {
    const value = label orelse return .unknown;
    if (std.mem.eql(u8, value, "success")) return .success;
    if (std.mem.eql(u8, value, "failure")) return .failure;
    return .unknown;
}

pub fn derive(tool_calls: []const object.StepToolCall) Outcome {
    if (tool_calls.len == 0) return .unknown;

    var saw_success = false;
    for (tool_calls) |tool_call| {
        const result = tool_call.result orelse continue;
        if (matchesAny(result, &failure_markers)) return .failure;
        if (matchesAny(result, &success_markers)) saw_success = true;
    }

    return if (saw_success) .success else .unknown;
}

const failure_markers = [_][]const u8{
    "error",
    "failed",
    "failure",
    "exception",
    "traceback",
    "not found",
    "non-zero",
    "exit code 1",
    "exit status 1",
};

const success_markers = [_][]const u8{
    "ok",
    "success",
    "passed",
    "0 failed",
    "all tests passed",
};

fn matchesAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsAsciiIgnoreCase(haystack, needle)) return true;
    }
    return false;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }

    return false;
}

test "derive reports failure when tool result looks like an error" {
    const tool_calls = [_]object.StepToolCall{
        .{ .tool_name = "bash", .args = "{\"command\":\"test\"}", .result = "error: tests failed" },
    };
    try std.testing.expect(derive(&tool_calls) == .failure);
}

test "derive reports success when tool result looks successful" {
    const tool_calls = [_]object.StepToolCall{
        .{ .tool_name = "bash", .args = "{\"command\":\"test\"}", .result = "ok" },
    };
    try std.testing.expect(derive(&tool_calls) == .success);
}

test "derive reports unknown when there are no recognizable tool results" {
    const tool_calls = [_]object.StepToolCall{
        .{ .tool_name = "bash", .args = "{\"command\":\"test\"}", .result = null },
    };
    try std.testing.expect(derive(&tool_calls) == .unknown);
}

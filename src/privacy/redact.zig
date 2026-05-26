const std = @import("std");

pub const Severity = enum {
    info,
    warn,
    @"error",
};

pub const Options = struct {
    custom_literals: []const []const u8 = &.{},
};

pub const Finding = struct {
    rule: []const u8,
    severity: Severity,
    start: usize,
    end: usize,
};

const sensitive_keys = [_][]const u8{
    "token",
    "secret",
    "password",
    "authorization",
    "api_key",
    "api-key",
    "apikey",
    "access_key",
    "access-key",
    "client_secret",
    "private_key",
};

pub fn redactAlloc(gpa: std.mem.Allocator, text: []const u8, options: Options) ![]u8 {
    const findings = try scanAlloc(gpa, text, options);
    defer gpa.free(findings);
    if (findings.len == 0) return try gpa.dupe(u8, text);

    std.mem.sort(Finding, findings, {}, lessThanFinding);

    var merged: std.ArrayList(Finding) = .empty;
    defer merged.deinit(gpa);
    for (findings) |finding| {
        if (merged.items.len == 0) {
            try merged.append(gpa, finding);
            continue;
        }
        const last = &merged.items[merged.items.len - 1];
        if (finding.start <= last.end) {
            last.end = @max(last.end, finding.end);
            last.severity = maxSeverity(last.severity, finding.severity);
            continue;
        }
        try merged.append(gpa, finding);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var cursor: usize = 0;
    for (merged.items) |finding| {
        try out.appendSlice(gpa, text[cursor..finding.start]);
        try out.appendSlice(gpa, "[REDACTED]");
        cursor = finding.end;
    }
    try out.appendSlice(gpa, text[cursor..]);
    return out.toOwnedSlice(gpa);
}

pub fn scanAlloc(gpa: std.mem.Allocator, text: []const u8, options: Options) ![]Finding {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer findings.deinit(gpa);

    try scanJsonSensitiveAssignments(gpa, text, &findings);
    try scanLooseSensitiveAssignments(gpa, text, &findings);
    try scanBearerTokens(gpa, text, &findings);
    try scanGitHubTokens(gpa, text, &findings);
    try scanAwsAccessKeys(gpa, text, &findings);
    try scanPrivateKeys(gpa, text, &findings);
    try scanCustomLiterals(gpa, text, options.custom_literals, &findings);

    return findings.toOwnedSlice(gpa);
}

fn scanJsonSensitiveAssignments(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '"') continue;
        const key_start = i + 1;
        const key_end = findStringEnd(text, key_start) orelse break;
        const key = text[key_start..key_end];
        var cursor = skipWhitespace(text, key_end + 1);
        if (cursor >= text.len or text[cursor] != ':') {
            i = key_end;
            continue;
        }
        if (!isSensitiveKey(key)) {
            i = key_end;
            continue;
        }

        cursor = skipWhitespace(text, cursor + 1);
        if (cursor >= text.len) break;

        if (text[cursor] == '"') {
            const value_start = cursor + 1;
            const value_end = findStringEnd(text, value_start) orelse text.len;
            try appendFinding(gpa, findings, .{
                .rule = "sensitive_assignment",
                .severity = .warn,
                .start = value_start,
                .end = value_end,
            });
            i = value_end;
            continue;
        }

        const value_end = trimLooseValueEnd(text, cursor, findLooseValueEnd(text, cursor));
        try appendFinding(gpa, findings, .{
            .rule = "sensitive_assignment",
            .severity = .warn,
            .start = cursor,
            .end = value_end,
        });
        i = value_end;
    }
}

fn scanLooseSensitiveAssignments(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var line_start: usize = 0;
    while (line_start < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
        const line = text[line_start..line_end];
        if (findAssignmentDelimiter(line)) |delimiter| {
            const delimiter_index = delimiter.index;
            if (delimiter.kind == .colon) {
                if (std.mem.indexOfScalar(u8, line[0..delimiter_index], '"') != null) {
                    line_start = if (line_end < text.len) line_end + 1 else text.len;
                    continue;
                }
                if (std.mem.indexOfScalar(u8, line[0..delimiter_index], '{') != null) {
                    line_start = if (line_end < text.len) line_end + 1 else text.len;
                    continue;
                }
            }
            const key = std.mem.trim(u8, line[0..delimiter_index], " \t\r\"'");
            if (isSensitiveKey(key)) {
                var value_start = delimiter_index + 1;
                while (value_start < line.len and std.ascii.isWhitespace(line[value_start])) : (value_start += 1) {}
                if (value_start < line.len and (line[value_start] == '"' or line[value_start] == '\'')) {
                    value_start += 1;
                }
                const value_end = trimLooseValueEnd(line, value_start, line.len);
                try appendFinding(gpa, findings, .{
                    .rule = "sensitive_assignment",
                    .severity = .warn,
                    .start = line_start + value_start,
                    .end = line_start + value_end,
                });
            }
        }
        line_start = if (line_end < text.len) line_end + 1 else text.len;
    }
}

fn scanBearerTokens(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var i: usize = 0;
    while (i + "bearer ".len <= text.len) : (i += 1) {
        if (!startsWithIgnoreCase(text[i..], "bearer ")) continue;
        const token_start = i + "bearer ".len;
        const token_end = scanTokenEnd(text, token_start);
        if (token_end > token_start + 5) {
            try appendFinding(gpa, findings, .{
                .rule = "bearer_token",
                .severity = .@"error",
                .start = token_start,
                .end = token_end,
            });
        }
        i = token_end;
    }
}

fn scanGitHubTokens(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    const prefixes = [_][]const u8{
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_",
    };
    for (prefixes) |prefix| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, text, start, prefix)) |idx| {
            const token_end = scanTokenEnd(text, idx);
            if (token_end >= idx + prefix.len + 6) {
                try appendFinding(gpa, findings, .{
                    .rule = "github_token",
                    .severity = .@"error",
                    .start = idx,
                    .end = token_end,
                });
            }
            start = idx + prefix.len;
        }
    }
}

fn scanAwsAccessKeys(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var i: usize = 0;
    while (i + 20 <= text.len) : (i += 1) {
        const candidate = text[i .. i + 20];
        if (!(std.mem.startsWith(u8, candidate, "AKIA") or std.mem.startsWith(u8, candidate, "ASIA"))) continue;
        if (!allUpperAlphaNum(candidate[4..])) continue;
        if (i > 0 and isIdentifierChar(text[i - 1])) continue;
        if (i + 20 < text.len and isIdentifierChar(text[i + 20])) continue;
        try appendFinding(gpa, findings, .{
            .rule = "aws_access_key",
            .severity = .@"error",
            .start = i,
            .end = i + 20,
        });
        i += 19;
    }
}

fn scanPrivateKeys(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, text, start, "-----BEGIN ")) |begin| {
        const header_end = std.mem.indexOfPos(u8, text, begin, "-----") orelse break;
        const header = text[begin .. header_end + 5];
        if (!containsIgnoreCase(header, "PRIVATE KEY")) {
            start = begin + 1;
            continue;
        }

        if (std.mem.indexOfPos(u8, text, header_end + 5, "-----END ")) |end_marker| {
            if (std.mem.indexOfPos(u8, text, end_marker, "PRIVATE KEY-----")) |tail_end| {
                try appendFinding(gpa, findings, .{
                    .rule = "private_key_block",
                    .severity = .@"error",
                    .start = begin,
                    .end = tail_end + "PRIVATE KEY-----".len,
                });
                start = tail_end + "PRIVATE KEY-----".len;
                continue;
            }
        }

        try appendFinding(gpa, findings, .{
            .rule = "private_key_block",
            .severity = .@"error",
            .start = begin,
            .end = text.len,
        });
        return;
    }
}

fn scanCustomLiterals(
    gpa: std.mem.Allocator,
    text: []const u8,
    literals: []const []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    for (literals) |literal| {
        if (literal.len == 0) continue;
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, text, start, literal)) |idx| {
            try appendFinding(gpa, findings, .{
                .rule = "custom_literal",
                .severity = .warn,
                .start = idx,
                .end = idx + literal.len,
            });
            start = idx + literal.len;
        }
    }
}

fn appendFinding(gpa: std.mem.Allocator, findings: *std.ArrayList(Finding), finding: Finding) !void {
    if (finding.end <= finding.start) return;
    try findings.append(gpa, finding);
}

fn lessThanFinding(_: void, a: Finding, b: Finding) bool {
    if (a.start == b.start) return a.end < b.end;
    return a.start < b.start;
}

fn maxSeverity(a: Severity, b: Severity) Severity {
    return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
}

fn findStringEnd(text: []const u8, start: usize) ?usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"' and (i == start or text[i - 1] != '\\')) return i;
    }
    return null;
}

fn skipWhitespace(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
    return i;
}

fn findLooseValueEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        if (text[i] == ',' or text[i] == '}' or text[i] == ']' or text[i] == '\n') return i;
    }
    return text.len;
}

fn trimLooseValueEnd(text: []const u8, start: usize, end: usize) usize {
    var i = end;
    while (i > start) : (i -= 1) {
        const c = text[i - 1];
        if (std.ascii.isWhitespace(c) or c == '"' or c == '\'' or c == ',') continue;
        return i;
    }
    return start;
}

fn isSensitiveKey(key: []const u8) bool {
    for (sensitive_keys) |needle| {
        if (containsIgnoreCase(key, needle)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |c, i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(c)) return false;
    }
    return true;
}

fn scanTokenEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and isTokenChar(text[i])) : (i += 1) {}
    return i;
}

fn isTokenChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

const AssignmentDelimiter = struct {
    index: usize,
    kind: enum { equals, colon },
};

fn findAssignmentDelimiter(line: []const u8) ?AssignmentDelimiter {
    if (std.mem.indexOfScalar(u8, line, '=')) |idx| {
        return .{ .index = idx, .kind = .equals };
    }
    if (std.mem.indexOfScalar(u8, line, ':')) |idx| {
        return .{ .index = idx, .kind = .colon };
    }
    return null;
}

fn allUpperAlphaNum(text: []const u8) bool {
    for (text) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

fn isIdentifierChar(c: u8) bool {
    return std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_' or c == '-';
}

test "redactAlloc masks sensitive JSON values" {
    const redacted = try redactAlloc(std.testing.allocator,
        \\{"token":"abc123","password":"hunter2","normal":"visible"}
    , .{});
    defer std.testing.allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "abc123") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "visible") != null);
}

test "scanAlloc finds bearer tokens and private keys" {
    const findings = try scanAlloc(std.testing.allocator,
        \\Authorization: Bearer secret-token-123
        \\-----BEGIN PRIVATE KEY-----
        \\abc
        \\-----END PRIVATE KEY-----
    , .{});
    defer std.testing.allocator.free(findings);
    try std.testing.expect(findings.len >= 2);
}

test "scanAlloc finds custom literals" {
    const findings = try scanAlloc(std.testing.allocator, "alpha super-secret omega", .{
        .custom_literals = &.{"super-secret"},
    });
    defer std.testing.allocator.free(findings);
    try std.testing.expectEqual(@as(usize, 1), findings.len);
    try std.testing.expectEqualStrings("custom_literal", findings[0].rule);
}

test "scanAlloc finds GitHub and AWS tokens" {
    const findings = try scanAlloc(std.testing.allocator,
        \\ghp_1234567890abcdefghij
        \\AKIA1234567890ABCDEF
    , .{});
    defer std.testing.allocator.free(findings);
    try std.testing.expect(findings.len >= 2);
}

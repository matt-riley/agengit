const std = @import("std");

const LinkKind = enum {
    local,
    external,
    mailto,
};

const LinkRef = struct {
    target: []const u8,
    line: usize,
    kind: LinkKind,
};

const DocPage = struct {
    path: []const u8,
    text: []const u8,
    anchors: std.StringHashMap(void),
    links: std.ArrayList(LinkRef),
};

pub fn main(init: std.process.Init) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    const ok = try runCheck(init.io, std.Io.Dir.cwd(), init.gpa, &stderr);
    try stderr.flush();
    if (!ok) std.process.exit(1);
}

pub fn runCheck(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    stderr: *std.Io.File.Writer,
) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    const files = try collectMarkdownFiles(io, root, aa);

    var pages: std.ArrayList(DocPage) = .empty;
    defer pages.deinit(aa);
    for (files.items) |path| {
        const text = try root.readFileAlloc(io, path, aa, .unlimited);
        try pages.append(aa, .{
            .path = path,
            .text = text,
            .anchors = try collectAnchors(aa, text),
            .links = try collectLinks(aa, text),
        });
    }

    var page_index = std.StringHashMap(usize).init(aa);
    for (pages.items, 0..) |page, index| {
        try page_index.put(page.path, index);
    }

    var ok = true;
    var skipped_external: usize = 0;
    for (pages.items) |page| {
        for (page.links.items) |link| {
            switch (link.kind) {
                .mailto => continue,
                .external => {
                    skipped_external += 1;
                },
                .local => {
                    if (!try validateLocalLink(io, root, aa, pages.items, &page_index, page.path, link, stderr)) {
                        ok = false;
                    }
                },
            }
        }
    }

    if (skipped_external > 0) {
        try stderr.interface.print(
            "warning: skipped {d} external links; external URLs do not fail this check.\n",
            .{skipped_external},
        );
    }
    return ok;
}

fn collectMarkdownFiles(io: std.Io, root: std.Io.Dir, gpa: std.mem.Allocator) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(gpa);

    const root_docs = [_][]const u8{ "README.md", "CHANGELOG.md" };
    for (root_docs) |path| {
        try assertFileExists(io, root, path);
        try files.append(gpa, try gpa.dupe(u8, path));
    }

    var docs_dir = root.openDir(io, "docs", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return files,
        else => return err,
    };
    defer docs_dir.close(io);

    var walker = try docs_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        try files.append(gpa, try std.fmt.allocPrint(gpa, "docs/{s}", .{entry.path}));
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return files;
}

fn collectAnchors(gpa: std.mem.Allocator, text: []const u8) !std.StringHashMap(void) {
    var anchors = std.StringHashMap(void).init(gpa);
    var counts = std.StringHashMap(usize).init(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_fence = false;

    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (isFenceLine(line)) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        const heading = headingText(line) orelse continue;
        const base_anchor = try slugifyHeading(gpa, heading);
        if (base_anchor.len == 0) continue;

        const existing = counts.get(base_anchor) orelse 0;
        try counts.put(base_anchor, existing + 1);

        const final_anchor = if (existing == 0)
            base_anchor
        else
            try std.fmt.allocPrint(gpa, "{s}-{d}", .{ base_anchor, existing });
        try anchors.put(final_anchor, {});
    }

    return anchors;
}

fn collectLinks(gpa: std.mem.Allocator, text: []const u8) !std.ArrayList(LinkRef) {
    var links: std.ArrayList(LinkRef) = .empty;
    errdefer links.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 1;
    var in_fence = false;

    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (isFenceLine(line)) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        try collectLinksInLine(gpa, line, line_no, &links);
    }

    return links;
}

fn collectLinksInLine(
    gpa: std.mem.Allocator,
    line: []const u8,
    line_no: usize,
    links: *std.ArrayList(LinkRef),
) !void {
    var in_code_span = false;
    var idx: usize = 0;
    while (idx < line.len) : (idx += 1) {
        if (line[idx] == '`') {
            in_code_span = !in_code_span;
            continue;
        }
        if (in_code_span) continue;

        if (std.mem.startsWith(u8, line[idx..], "<!--")) {
            const comment_end = std.mem.indexOfPos(u8, line, idx + 4, "-->") orelse break;
            idx = comment_end + 2;
            continue;
        }

        if (line[idx] == '<') {
            const end = std.mem.indexOfScalarPos(u8, line, idx + 1, '>') orelse continue;
            const raw = line[idx + 1 .. end];
            if (classifyLink(raw)) |kind| {
                try links.append(gpa, .{
                    .target = try gpa.dupe(u8, raw),
                    .line = line_no,
                    .kind = kind,
                });
                idx = end;
            }
            continue;
        }

        if (line[idx] != '[' and !(line[idx] == '!' and idx + 1 < line.len and line[idx + 1] == '[')) continue;

        const bracket_start = if (line[idx] == '!') idx + 1 else idx;
        const close_bracket = std.mem.indexOfScalarPos(u8, line, bracket_start + 1, ']') orelse continue;
        if (close_bracket + 1 >= line.len or line[close_bracket + 1] != '(') continue;

        var cursor = close_bracket + 2;
        var depth: usize = 1;
        while (cursor < line.len and depth > 0) : (cursor += 1) {
            switch (line[cursor]) {
                '\\' => {
                    if (cursor + 1 < line.len) cursor += 1;
                },
                '(' => depth += 1,
                ')' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0 or cursor <= close_bracket + 2) continue;

        const raw_target = line[close_bracket + 2 .. cursor - 1];
        const target = extractMarkdownTarget(raw_target) orelse continue;
        const kind = classifyLink(target) orelse continue;
        try links.append(gpa, .{
            .target = try gpa.dupe(u8, target),
            .line = line_no,
            .kind = kind,
        });
        idx = cursor - 1;
    }
}

fn validateLocalLink(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    pages: []const DocPage,
    page_index: *const std.StringHashMap(usize),
    source_path: []const u8,
    link: LinkRef,
    stderr: *std.Io.File.Writer,
) !bool {
    const split = splitFragment(link.target);
    const fragment = split.fragment;

    const target_path = if (split.path.len == 0)
        source_path
    else
        try normalizeRelativePath(gpa, source_path, split.path);

    if (!pathExists(io, root, target_path)) {
        try stderr.interface.print(
            "error: {s}:{d}: missing local target {s}\n",
            .{ source_path, link.line, link.target },
        );
        return false;
    }

    if (fragment.len == 0) return true;

    const page_idx = page_index.get(target_path) orelse {
        try stderr.interface.print(
            "error: {s}:{d}: cannot resolve anchor #{s} in non-markdown target {s}\n",
            .{ source_path, link.line, fragment, link.target },
        );
        return false;
    };
    const page = pages[page_idx];
    if (page.anchors.get(fragment) == null) {
        try stderr.interface.print(
            "error: {s}:{d}: missing anchor #{s} in {s}\n",
            .{ source_path, link.line, fragment, target_path },
        );
        return false;
    }
    return true;
}

fn splitFragment(target: []const u8) struct { path: []const u8, fragment: []const u8 } {
    if (std.mem.indexOfScalar(u8, target, '#')) |idx| {
        return .{ .path = target[0..idx], .fragment = target[idx + 1 ..] };
    }
    return .{ .path = target, .fragment = "" };
}

fn normalizeRelativePath(gpa: std.mem.Allocator, source_path: []const u8, raw_target: []const u8) ![]const u8 {
    const source_dir = dirName(source_path);
    const joined = if (raw_target.len == 0 or raw_target[0] == '/')
        raw_target
    else if (source_dir.len == 0)
        raw_target
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}", .{ source_dir, raw_target });

    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(gpa);

    var iter = std.mem.splitScalar(u8, joined, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(gpa, part);
    }

    if (parts.items.len == 0) return try gpa.dupe(u8, ".");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);
    for (parts.items, 0..) |part, index| {
        if (index > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    return try out.toOwnedSlice(gpa);
}

fn headingText(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    var hashes: usize = 0;
    while (hashes < trimmed.len and hashes < 6 and trimmed[hashes] == '#') : (hashes += 1) {}
    if (hashes == 0 or hashes >= trimmed.len) return null;
    if (trimmed[hashes] != ' ' and trimmed[hashes] != '\t') return null;
    const body = std.mem.trim(u8, trimmed[hashes + 1 ..], " \t");
    return std.mem.trimEnd(u8, body, " #\t");
}

fn slugifyHeading(gpa: std.mem.Allocator, heading: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    var pending_dash = false;
    for (heading) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (pending_dash and out.items.len > 0) try out.append(gpa, '-');
            pending_dash = false;
            try out.append(gpa, std.ascii.toLower(ch));
            continue;
        }

        switch (ch) {
            ' ', '-', '_' => pending_dash = out.items.len > 0,
            else => {},
        }
    }

    return try out.toOwnedSlice(gpa);
}

fn isFenceLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~");
}

fn extractMarkdownTarget(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '<') {
        const end = std.mem.indexOfScalar(u8, trimmed, '>') orelse return null;
        return trimmed[1..end];
    }

    const whitespace = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..whitespace];
}

fn classifyLink(target: []const u8) ?LinkKind {
    if (target.len > 0 and target[0] == '/') return null;
    const tag_name_end = std.mem.indexOfAny(u8, target, " \t/>") orelse target.len;
    const tag_name = target[0..tag_name_end];
    if (std.mem.eql(u8, tag_name, "video") or std.mem.eql(u8, tag_name, "source")) return null;
    if (std.mem.startsWith(u8, target, "mailto:")) return .mailto;
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://")) return .external;
    if (target.len == 0) return null;
    return .local;
}

fn assertFileExists(io: std.Io, root: std.Io.Dir, path: []const u8) !void {
    var file = try root.openFile(io, path, .{});
    defer file.close(io);
}

fn pathExists(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    var file = root.openFile(io, path, .{}) catch |file_err| switch (file_err) {
        error.FileNotFound => {
            var dir = root.openDir(io, path, .{}) catch return false;
            dir.close(io);
            return true;
        },
        else => return false,
    };
    file.close(io);
    return true;
}

fn dirName(path: []const u8) []const u8 {
    const sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..sep];
}

test "slugifyHeading matches github-style duplicate anchors" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("adr-018-build-and-lint-coverage", try slugifyHeading(gpa, "ADR 018: Build and lint coverage"));
    try std.testing.expectEqualStrings("status", try slugifyHeading(gpa, "Status"));
}

test "runCheck validates relative paths and anchors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeFile(io, tmp.dir, "README.md", "# Root\n\nSee [ADR](docs/adr/001-test.md#details).\n");
    try writeFile(io, tmp.dir, "CHANGELOG.md", "# Changelog\n");
    try writeFile(io, tmp.dir, "docs/adr/001-test.md", "# Details\n\n## Details\n");

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    try std.testing.expect(try runCheck(io, tmp.dir, gpa, &stderr));
}

test "runCheck fails broken local anchors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeFile(io, tmp.dir, "README.md", "# Root\n\nSee [ADR](docs/adr/001-test.md#missing).\n");
    try writeFile(io, tmp.dir, "CHANGELOG.md", "# Changelog\n");
    try writeFile(io, tmp.dir, "docs/adr/001-test.md", "# Details\n");

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    try std.testing.expect(!(try runCheck(io, tmp.dir, gpa, &stderr)));
}

fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        try dir.createDirPath(io, path[0..sep]);
    }
    var file = try dir.createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeAll(io, content);
}

const std = @import("std");
const builtin = @import("builtin");
const fs_mod = @import("fs.zig");

pub const MalformedJson = struct {
    path: []const u8,
    offset: u64,
    line: u64,
    column: u64,
};

pub const LoadResult = union(enum) {
    missing,
    object: std.json.Value,
    malformed: MalformedJson,
    not_object,
};

pub const WriteOptions = struct {
    crash_after_tmp_write: bool = false,
};

pub fn loadObject(io: std.Io, aa: std.mem.Allocator, path: []const u8) !LoadResult {
    const text = (try readFileAllocOrNull(io, aa, path)) orelse return .missing;
    defer aa.free(text);

    var scanner = std.json.Scanner.initCompleteInput(aa, text);
    defer scanner.deinit();

    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);

    const parsed = std.json.parseFromTokenSourceLeaky(std.json.Value, aa, &scanner, .{
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .malformed = .{
            .path = path,
            .offset = diagnostics.getByteOffset(),
            .line = diagnostics.getLine(),
            .column = diagnostics.getColumn(),
        } },
    };

    if (parsed != .object) return .not_object;
    return .{ .object = parsed };
}

pub fn writeAtomic(
    io: std.Io,
    aa: std.mem.Allocator,
    path: []const u8,
    value: std.json.Value,
    opts: WriteOptions,
) !void {
    const json = try std.json.Stringify.valueAlloc(aa, value, .{ .whitespace = .indent_2 });
    defer aa.free(json);
    try writeAtomicBytes(io, aa, path, json, .{
        .replace = true,
        .crash_after_tmp_write = opts.crash_after_tmp_write,
    });
}

pub fn backupOnce(
    io: std.Io,
    aa: std.mem.Allocator,
    path: []const u8,
    force: bool,
) !bool {
    const content = (try readFileAllocOrNull(io, aa, path)) orelse return false;
    defer aa.free(content);

    const backup_path = try std.fmt.allocPrint(aa, "{s}.agit.bak", .{path});
    defer aa.free(backup_path);
    if (!force) {
        const existing = std.Io.Dir.cwd().openFile(io, backup_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |file| {
            file.close(io);
            return false;
        }
    }

    try writeAtomicBytes(io, aa, backup_path, content, .{
        .replace = force,
        .crash_after_tmp_write = false,
    });
    return true;
}

const WriteBytesOptions = struct {
    replace: bool,
    crash_after_tmp_write: bool,
};

fn writeAtomicBytes(
    io: std.Io,
    aa: std.mem.Allocator,
    path: []const u8,
    content: []const u8,
    opts: WriteBytesOptions,
) !void {
    const dir_name = std.fs.path.dirname(path) orelse ".";
    const base_name = std.fs.path.basename(path);
    var tmp_path: []u8 = undefined;
    var tmp_file: std.Io.File = undefined;
    const cwd = std.Io.Dir.cwd();

    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        tmp_path = if (std.mem.eql(u8, dir_name, "."))
            try std.fmt.allocPrint(
                aa,
                "{s}.agit-tmp-{d}-{d}-{d}",
                .{ base_name, currentPid(), std.Io.Timestamp.now(io, .real).toMilliseconds(), attempt },
            )
        else
            try std.fmt.allocPrint(
                aa,
                "{s}/{s}.agit-tmp-{d}-{d}-{d}",
                .{ dir_name, base_name, currentPid(), std.Io.Timestamp.now(io, .real).toMilliseconds(), attempt },
            );
        tmp_file = cwd.createFile(io, tmp_path, .{ .exclusive = true, .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                aa.free(tmp_path);
                continue;
            },
            else => {
                aa.free(tmp_path);
                return err;
            },
        };
        break;
    }
    defer aa.free(tmp_path);
    defer tmp_file.close(io);
    errdefer cwd.deleteFile(io, tmp_path) catch {};

    try tmp_file.writeStreamingAll(io, content);
    try tmp_file.sync(io);

    if (opts.crash_after_tmp_write) {
        std.process.abort();
    }

    if (!opts.replace) {
        const existing = cwd.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |file| {
            file.close(io);
            return error.PathAlreadyExists;
        }
    }

    try fs_mod.renameDurable(io, cwd, tmp_path, cwd, path);
}

fn currentPid() if (builtin.os.tag == .windows) u32 else std.posix.pid_t {
    if (builtin.os.tag == .windows) {
        return std.os.windows.GetCurrentProcessId();
    } else if (builtin.os.tag == .linux) {
        return std.os.linux.getpid();
    } else {
        return std.c.getpid();
    }
}

fn readFileAllocOrNull(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    if (buf.len > 0) {
        _ = try file.readPositionalAll(io, buf, 0);
    }
    return buf;
}

fn testPath(io: std.Io, dir: std.Io.Dir, gpa: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(io, &real_buf);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ real_buf[0..n], rel_path });
}

fn writeTestFile(io: std.Io, dir: std.Io.Dir, rel_path: []const u8, content: []const u8) !void {
    var file = try dir.createFile(io, rel_path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "loadObject returns missing for absent file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const path = try testPath(io, tmp.dir, gpa, "missing.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const loaded = try loadObject(io, arena.allocator(), path);
    try std.testing.expect(loaded == .missing);
}

test "loadObject returns malformed with diagnostics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "bad.json", "{not-json");
    const path = try testPath(io, tmp.dir, gpa, "bad.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const loaded = try loadObject(io, arena.allocator(), path);
    try std.testing.expect(loaded == .malformed);
    try std.testing.expect(loaded.malformed.offset > 0);
}

test "loadObject returns not_object for non-object root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "array.json", "[]");
    const path = try testPath(io, tmp.dir, gpa, "array.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const loaded = try loadObject(io, arena.allocator(), path);
    try std.testing.expect(loaded == .not_object);
}

test "backupOnce writes exact bytes and does not overwrite without force" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "settings.json", "{not-json");
    const path = try testPath(io, tmp.dir, gpa, "settings.json");
    defer gpa.free(path);

    try std.testing.expect(try backupOnce(io, gpa, path, false));

    const backup_path = try std.fmt.allocPrint(gpa, "{s}.agit.bak", .{path});
    defer gpa.free(backup_path);
    const backup = try std.Io.Dir.cwd().readFileAlloc(io, backup_path, gpa, .unlimited);
    defer gpa.free(backup);
    try std.testing.expectEqualStrings("{not-json", backup);

    try writeTestFile(io, tmp.dir, "settings.json", "{\"new\":true}");
    try std.testing.expect(!(try backupOnce(io, gpa, path, false)));
    const backup2 = try std.Io.Dir.cwd().readFileAlloc(io, backup_path, gpa, .unlimited);
    defer gpa.free(backup2);
    try std.testing.expectEqualStrings("{not-json", backup2);
}

test "backupOnce overwrites backup when force is true" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try writeTestFile(io, tmp.dir, "settings.json", "{old}");
    const path = try testPath(io, tmp.dir, gpa, "settings.json");
    defer gpa.free(path);
    _ = try backupOnce(io, gpa, path, false);

    try writeTestFile(io, tmp.dir, "settings.json", "{new}");
    try std.testing.expect(try backupOnce(io, gpa, path, true));

    const backup_path = try std.fmt.allocPrint(gpa, "{s}.agit.bak", .{path});
    defer gpa.free(backup_path);
    const backup = try std.Io.Dir.cwd().readFileAlloc(io, backup_path, gpa, .unlimited);
    defer gpa.free(backup);
    try std.testing.expectEqualStrings("{new}", backup);
}

test "writeAtomic writes object via temp rename flow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const path = try testPath(io, tmp.dir, gpa, "settings.json");
    defer gpa.free(path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = std.json.ObjectMap.empty;
    try root.put(aa, "ok", std.json.Value{ .bool = true });
    try writeAtomic(io, aa, path, std.json.Value{ .object = root }, .{});

    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"ok\": true") != null);
}

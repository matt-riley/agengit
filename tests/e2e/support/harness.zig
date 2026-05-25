const std = @import("std");

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
        self.* = undefined;
    }
};

pub const Sandbox = struct {
    tmpdir: std.testing.TmpDir,
    gpa: std.mem.Allocator,
    io: std.Io,
    root: []u8,
    home: []u8,
    cwd: []u8,
    bin: []u8,
    agit_bin: []u8,
    keep_tempdir: bool,

    pub fn init(gpa: std.mem.Allocator) !Sandbox {
        const io = std.testing.io;
        var tmpdir = std.testing.tmpDir(.{});
        errdefer tmpdir.cleanup();

        try tmpdir.dir.createDirPath(io, "home");
        try tmpdir.dir.createDirPath(io, "repo");
        try tmpdir.dir.createDirPath(io, "bin");

        var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmpdir.parent_dir.realPath(io, &parent_buf);
        const root = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parent_buf[0..n], tmpdir.sub_path });
        errdefer gpa.free(root);

        const home = try std.fmt.allocPrint(gpa, "{s}/home", .{root});
        errdefer gpa.free(home);
        const cwd = try std.fmt.allocPrint(gpa, "{s}/repo", .{root});
        errdefer gpa.free(cwd);
        const bin = try std.fmt.allocPrint(gpa, "{s}/bin", .{root});
        errdefer gpa.free(bin);

        const agit_bin = try resolveAgitBinary(gpa, io);
        errdefer gpa.free(agit_bin);

        const keep_tempdir = envFlagEnabled(gpa, io, "AGIT_KEEP_TEMPDIR");

        return .{
            .tmpdir = tmpdir,
            .gpa = gpa,
            .io = io,
            .root = root,
            .home = home,
            .cwd = cwd,
            .bin = bin,
            .agit_bin = agit_bin,
            .keep_tempdir = keep_tempdir,
        };
    }

    pub fn deinit(self: *Sandbox) void {
        self.gpa.free(self.root);
        self.gpa.free(self.home);
        self.gpa.free(self.cwd);
        self.gpa.free(self.bin);
        self.gpa.free(self.agit_bin);
        if (self.keep_tempdir) {
            self.tmpdir.dir.close(self.io);
            self.tmpdir.parent_dir.close(self.io);
        } else {
            self.tmpdir.cleanup();
        }
        self.* = undefined;
    }

    pub fn run(self: *Sandbox, argv: []const []const u8, stdin: ?[]const u8) !RunResult {
        var child_argv: std.ArrayList([]const u8) = .empty;
        defer child_argv.deinit(self.gpa);

        const home_env = try std.fmt.allocPrint(self.gpa, "HOME={s}", .{self.home});
        defer self.gpa.free(home_env);
        const path_env = try std.fmt.allocPrint(self.gpa, "PATH={s}:/usr/bin:/bin", .{self.bin});
        defer self.gpa.free(path_env);

        try child_argv.appendSlice(self.gpa, &.{ "/usr/bin/env", home_env, path_env, self.agit_bin });
        try child_argv.appendSlice(self.gpa, argv);

        var child = try std.process.spawn(self.io, .{
            .argv = child_argv.items,
            .cwd = .{ .path = self.cwd },
            .stdin = if (stdin == null) .ignore else .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
        defer child.kill(self.io);

        if (stdin) |payload| {
            try child.stdin.?.writeStreamingAll(self.io, payload);
            child.stdin.?.close(self.io);
            child.stdin = null;
        }

        var stdout_reader_buf: [4096]u8 = undefined;
        var stderr_reader_buf: [4096]u8 = undefined;
        var stdout_reader = child.stdout.?.reader(self.io, &stdout_reader_buf);
        var stderr_reader = child.stderr.?.reader(self.io, &stderr_reader_buf);
        const stdout = try stdout_reader.interface.allocRemaining(self.gpa, .unlimited);
        errdefer self.gpa.free(stdout);
        const stderr = try stderr_reader.interface.allocRemaining(self.gpa, .unlimited);
        errdefer self.gpa.free(stderr);

        child.stdout.?.close(self.io);
        child.stdout = null;
        child.stderr.?.close(self.io);
        child.stderr = null;

        const term = try child.wait(self.io);
        const exit_code: u8 = switch (term) {
            .exited => |code| code,
            else => 255,
        };

        return .{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
    }

    pub fn writeRepoFile(self: *Sandbox, rel_path: []const u8, content: []const u8) !void {
        try writeAbsolute(self.io, self.cwd, rel_path, content);
    }

    pub fn writeHomeFile(self: *Sandbox, rel_path: []const u8, content: []const u8) !void {
        try writeAbsolute(self.io, self.home, rel_path, content);
    }

    pub fn expectFile(self: *Sandbox, rel_path: []const u8, expected: []const u8) !void {
        const abs_path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.cwd, rel_path });
        defer self.gpa.free(abs_path);
        const got = try std.Io.Dir.cwd().readFileAlloc(self.io, abs_path, self.gpa, .unlimited);
        defer self.gpa.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }

    pub fn readRepoFileAlloc(self: *Sandbox, rel_path: []const u8) ![]u8 {
        const abs_path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.cwd, rel_path });
        defer self.gpa.free(abs_path);
        return std.Io.Dir.cwd().readFileAlloc(self.io, abs_path, self.gpa, .unlimited);
    }

    pub fn createFakeAgent(self: *Sandbox, name: []const u8) !void {
        const script_path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.bin, name });
        defer self.gpa.free(script_path);
        try writeAbsolute(self.io, self.bin, name, "#!/bin/sh\nexit 0\n");
        const chmod_result = try std.process.run(self.gpa, self.io, .{
            .argv = &.{ "/bin/chmod", "+x", script_path },
        });
        defer self.gpa.free(chmod_result.stdout);
        defer self.gpa.free(chmod_result.stderr);
        try std.testing.expect(chmod_result.term == .exited and chmod_result.term.exited == 0);
    }
};

fn envFlagEnabled(gpa: std.mem.Allocator, io: std.Io, name: []const u8) bool {
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "/usr/bin/printenv", name },
    }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) return false;
    const trimmed = std.mem.trim(u8, res.stdout, " \r\n");
    return std.mem.eql(u8, trimmed, "1");
}

fn writeAbsolute(io: std.Io, base_abs: []const u8, rel_path: []const u8, content: []const u8) !void {
    var cwd = std.Io.Dir.cwd();
    const sep = std.mem.lastIndexOfScalar(u8, rel_path, '/');
    if (sep) |idx| {
        const dir_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ base_abs, rel_path[0..idx] });
        defer std.testing.allocator.free(dir_path);
        try cwd.createDirPath(io, dir_path);
    }
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ base_abs, rel_path });
    defer std.testing.allocator.free(abs_path);
    var f = try cwd.createFile(io, abs_path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, content);
}

fn resolveAgitBinary(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.FileNotFound;
    var current = try gpa.dupe(u8, exe_dir);
    defer gpa.free(current);

    while (true) {
        const candidate = try std.fmt.allocPrint(gpa, "{s}/zig-out/bin/agit", .{current});
        var file = std.Io.Dir.cwd().openFile(io, candidate, .{}) catch {
            gpa.free(candidate);
            const parent = std.fs.path.dirname(current) orelse return error.FileNotFound;
            if (parent.len == current.len and std.mem.eql(u8, parent, current)) return error.FileNotFound;
            const next = try gpa.dupe(u8, parent);
            gpa.free(current);
            current = next;
            continue;
        };
        file.close(io);
        return candidate;
    }
}

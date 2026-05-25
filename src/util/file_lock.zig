const std = @import("std");
const builtin = @import("builtin");

const default_timeout_ms: i64 = 10_000;
const default_stale_after_ms: i64 = 5 * 60 * 1000;

var configured_timeout_ms = std.atomic.Value(i64).init(default_timeout_ms);

pub fn configureFromEnviron(environ: std.process.Environ) void {
    const env_value = environ.getPosix("AGIT_LOCK_TIMEOUT_MS") orelse {
        configured_timeout_ms.store(default_timeout_ms, .release);
        return;
    };
    const trimmed = std.mem.trim(u8, env_value, " \t\r\n");
    if (trimmed.len == 0) {
        configured_timeout_ms.store(default_timeout_ms, .release);
        return;
    }
    const parsed = std.fmt.parseInt(i64, trimmed, 10) catch {
        configured_timeout_ms.store(default_timeout_ms, .release);
        return;
    };
    configured_timeout_ms.store(if (parsed > 0) parsed else default_timeout_ms, .release);
}

pub fn setTimeoutMsForTesting(timeout_ms: i64) void {
    configured_timeout_ms.store(if (timeout_ms > 0) timeout_ms else default_timeout_ms, .release);
}

fn effectiveDefaultTimeoutMs() i64 {
    return configured_timeout_ms.load(.acquire);
}

/// Cooperative advisory lock backed by a lock file.
///
/// Protocol:
/// 1. Create the lock file with exclusive=true (atomic O_CREAT|O_EXCL) and write a JSON lock record.
/// 2. On contention, read and validate the lock owner process.
///    - Linux: validate PID + /proc/<pid>/exe.
///    - macOS: validate PID + proc_pidpath.
///    - Other platforms: validate PID-only.
/// 3. Stale lock: delete and re-acquire.
/// 4. Live lock: retry with exponential backoff until timeout_ms is exceeded.
/// 5. Unlock: delete the lock file.
pub const LockFile = struct {
    dir: std.Io.Dir,
    sub_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    sub_path_len: usize = 0,

    pub const Options = struct {
        timeout_ms: ?i64 = null,
        stale_after_ms: i64 = default_stale_after_ms,
        initial_delay_ms: i64 = 5,
        max_delay_ms: i64 = 250,
    };

    pub const AcquireError = error{
        LockTimeout,
        SubPathTooLong,
        Canceled,
    } || std.Io.File.OpenError || std.Io.File.ReadPositionalError || std.Io.File.Writer.Error || std.Io.Dir.DeleteFileError || std.json.Stringify.Error;

    pub const ReleaseError = std.Io.Dir.DeleteFileError;

    /// Acquire the lock at dir/sub_path, blocking up to opts.timeout_ms milliseconds.
    pub fn acquire(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, opts: Options) AcquireError!LockFile {
        return acquireWithTimeout(io, dir, sub_path, opts);
    }

    pub fn acquireWithTimeout(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, opts: Options) AcquireError!LockFile {
        if (sub_path.len >= std.fs.max_path_bytes) return error.SubPathTooLong;

        var self: LockFile = .{ .dir = dir };
        @memcpy(self.sub_path_buf[0..sub_path.len], sub_path);
        self.sub_path_len = sub_path.len;

        const timeout_ms = opts.timeout_ms orelse effectiveDefaultTimeoutMs();
        const clock = std.Io.Clock.awake;
        const start = std.Io.Timestamp.now(io, clock);
        const timeout_dur = std.Io.Duration.fromMilliseconds(timeout_ms);
        const deadline = start.addDuration(timeout_dur);
        var delay_ms = opts.initial_delay_ms;

        while (true) {
            switch (try tryAcquireOnce(io, dir, sub_path)) {
                .acquired => return self,
                .contended => {
                    if (try shouldReclaimStale(io, dir, sub_path, opts.stale_after_ms)) {
                        dir.deleteFile(io, sub_path) catch |err| switch (err) {
                            error.FileNotFound => {},
                            else => return err,
                        };
                        switch (try tryAcquireOnce(io, dir, sub_path)) {
                            .acquired => return self,
                            .contended => {},
                        }
                    }
                },
            }

            const now = std.Io.Timestamp.now(io, clock);
            if (now.durationTo(deadline).nanoseconds <= 0) return error.LockTimeout;

            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(delay_ms), clock) catch {};
            delay_ms = @min(delay_ms * 2, opts.max_delay_ms);
        }
    }

    /// Release the lock by deleting the lock file.
    pub fn release(self: *LockFile, io: std.Io) void {
        self.releaseChecked(io) catch |err| {
            handleReleaseError(self, io, err);
        };
    }

    pub fn releaseChecked(self: *LockFile, io: std.Io) ReleaseError!void {
        const sub_path = self.sub_path_buf[0..self.sub_path_len];
        try self.dir.deleteFile(io, sub_path);
        self.sub_path_len = 0;
    }
};

pub const LockRecord = struct {
    pid: OsPid,
    started_at: i64,
    exe_path: []const u8,
    hostname: []const u8,
};

const TryResult = union(enum) {
    acquired,
    contended,
};

const OsPid = if (builtin.os.tag == .windows) u32 else std.posix.pid_t;

fn tryAcquireOnce(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) LockFile.AcquireError!TryResult {
    const file = dir.createFile(io, sub_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return .contended,
        else => return err,
    };
    defer file.close(io);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = currentExePathInto(io, &exe_buf) catch "unknown";
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = currentHostNameInto(&host_buf);
    const record: LockRecord = .{
        .pid = currentPid(),
        .started_at = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        .exe_path = exe_path,
        .hostname = hostname,
    };
    var write_buf: [2048]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try std.json.Stringify.value(record, .{}, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.flush();
    try file.sync(io);

    return .acquired;
}

fn shouldReclaimStale(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, stale_after_ms: i64) LockFile.AcquireError!bool {
    const maybe_record = try readLockRecord(io, dir, sub_path);
    if (maybe_record == null) return true;
    var parsed = maybe_record.?;
    defer parsed.deinit();
    const record = parsed.value;

    if (!isProcessAlive(record.pid)) return true;

    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    if (!std.mem.eql(u8, record.hostname, currentHostNameInto(&host_buf))) return true;

    const age_ms = std.Io.Timestamp.now(io, .real).toMilliseconds() - record.started_at;
    if (age_ms > stale_after_ms) return true;

    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const ours = isProcessOurs(io, record.pid, record.exe_path);
        if (!ours) return true;
    }

    return false;
}

fn readLockRecord(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) LockFile.AcquireError!?std.json.Parsed(LockRecord) {
    var content_buf: [4096]u8 = undefined;
    const file = dir.openFile(io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    const n = try file.readPositionalAll(io, &content_buf, 0);
    const text = std.mem.trim(u8, content_buf[0..n], "\n\r ");

    const gpa = std.heap.page_allocator;
    return std.json.parseFromSlice(LockRecord, gpa, text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch null;
}

fn currentPid() OsPid {
    if (builtin.os.tag == .windows) {
        return std.os.windows.GetCurrentProcessId();
    } else if (builtin.os.tag == .linux) {
        return std.os.linux.getpid();
    } else {
        // macOS/BSD: libc is always linked on these platforms.
        return std.c.getpid();
    }
}

fn currentExePathInto(io: std.Io, out: []u8) ![]const u8 {
    const n = try std.process.executablePath(io, out);
    return out[0..n];
}

fn currentHostNameInto(out: *[std.posix.HOST_NAME_MAX]u8) []const u8 {
    if (builtin.os.tag == .windows) return "unknown";
    return std.posix.gethostname(out) catch "unknown";
}

fn isProcessAlive(pid: OsPid) bool {
    if (builtin.os.tag == .windows) {
        // TODO: use OpenProcess + GetExitCodeProcess when std bindings are available.
        return pid != 0;
    } else {
        return isProcessAlivePosix(pid);
    }
}

fn isProcessAlivePosix(pid: std.posix.pid_t) bool {
    // PID <= 0 is never a real process (0 = process group special, <0 = broadcast).
    if (pid <= 0) return false;
    // Signal 0 does not send a signal; it only checks if the process exists.
    // The SIG enum is non-exhaustive so @enumFromInt(0) is valid.
    const sig_zero: std.posix.SIG = @enumFromInt(0);
    std.posix.kill(pid, sig_zero) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn isProcessOurs(io: std.Io, pid: OsPid, expected_exe: []const u8) bool {
    var actual_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const actual_exe = switch (builtin.os.tag) {
        .linux => readLinuxExePath(io, @intCast(pid), &actual_exe_buf),
        .macos => readMacExePath(@intCast(pid), &actual_exe_buf),
        else => return true,
    } orelse return true;

    const normalized_actual = trimDeletedSuffix(actual_exe);
    const normalized_expected = trimDeletedSuffix(expected_exe);
    return std.mem.eql(u8, normalized_actual, normalized_expected);
}

fn readLinuxExePath(io: std.Io, pid: std.posix.pid_t, out_buf: []u8) ?[]const u8 {
    var path_buf: [64]u8 = undefined;
    const proc_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/exe", .{pid}) catch return null;
    const n = std.Io.Dir.readLinkAbsolute(io, proc_path, out_buf) catch return null;
    return out_buf[0..n];
}

extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

fn readMacExePath(pid: std.posix.pid_t, out_buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const rc = proc_pidpath(@intCast(pid), out_buf.ptr, @intCast(out_buf.len));
    if (rc <= 0) return null;
    return out_buf[0..@intCast(rc)];
}

fn trimDeletedSuffix(path: []const u8) []const u8 {
    const suffix = " (deleted)";
    if (std.mem.endsWith(u8, path, suffix)) return path[0 .. path.len - suffix.len];
    return path;
}

fn handleReleaseError(self: *LockFile, io: std.Io, err: anyerror) void {
    if (builtin.mode == .Debug) {
        std.debug.panic("failed to release lock {s}: {s}", .{
            self.sub_path_buf[0..self.sub_path_len],
            @errorName(err),
        });
    }
    logReleaseError(self, io, err);
}

fn logReleaseError(self: *LockFile, io: std.Io, err: anyerror) void {
    // Best-effort only: never throw from release in non-debug builds.
    var line_buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "{{\"ts\":{d},\"context\":\"file-lock-release\",\"code\":\"lock_release_failed\",\"message\":\"failed to delete lock file on release\",\"field\":\"sub_path\",\"err\":\"{s}\",\"lock_path\":\"{s}\"}}\n",
        .{
            std.Io.Timestamp.now(io, .real).toMilliseconds(),
            @errorName(err),
            self.sub_path_buf[0..self.sub_path_len],
        },
    ) catch {
        return;
    };

    // Avoid recursive logging if the failing lock is itself the hook-error lock.
    if (std.mem.eql(u8, self.sub_path_buf[0..self.sub_path_len], "log/hook-error.log.lock")) {
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        stderr.interface.writeAll("[agit lock release] failed to release log lock\n") catch {};
        stderr.flush() catch {};
        return;
    }

    var file = self.dir.createFile(io, "log/hook-error.log", .{
        .read = true,
        .truncate = false,
        .make_path = true,
    }) catch {
        var stderr_buf: [512]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        stderr.interface.writeAll("[agit lock release] failed to append hook-error.log\n") catch {};
        stderr.flush() catch {};
        return;
    };
    defer file.close(io);

    const offset = file.length(io) catch return;
    _ = file.writePositionalAll(io, line, offset) catch return;
    _ = file.sync(io) catch {};
}

test "acquire and release lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var lock = try LockFile.acquire(io, tmp.dir, "test.lock", .{ .timeout_ms = 1_000 });
    defer lock.release(io);

    const err = LockFile.acquire(io, tmp.dir, "test.lock", .{ .timeout_ms = 50 });
    try std.testing.expectError(error.LockTimeout, err);
}

test "lock file content is JSON line with metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var lock = try LockFile.acquire(io, tmp.dir, "test.lock", .{ .timeout_ms = 1_000 });
    defer lock.release(io);

    const text = try tmp.dir.readFileAlloc(io, "test.lock", gpa, .unlimited);
    defer gpa.free(text);
    var parsed = try std.json.parseFromSlice(LockRecord, gpa, std.mem.trim(u8, text, " \r\n"), .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expect(parsed.value.pid > 0);
    try std.testing.expect(parsed.value.started_at > 0);
    try std.testing.expect(parsed.value.exe_path.len > 0);
    try std.testing.expect(parsed.value.hostname.len > 0);
}

test "stale pid lock is reclaimed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    {
        const f = try tmp.dir.createFile(io, "stale.lock", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "{\"pid\":0,\"started_at\":0,\"exe_path\":\"/tmp/old\",\"hostname\":\"oldhost\"}\n");
    }

    var lock = try LockFile.acquire(io, tmp.dir, "stale.lock", .{ .timeout_ms = 1_000 });
    lock.release(io);
}

test "alive wrong-exe lock is reclaimed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const pid = currentPid();
    {
        const f = try tmp.dir.createFile(io, "wrong-exe.lock", .{});
        defer f.close(io);
        var line_buf: [256]u8 = undefined;
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = currentHostNameInto(&host_buf);
        const line = std.fmt.bufPrint(
            &line_buf,
            "{{\"pid\":{d},\"started_at\":{d},\"exe_path\":\"{s}\",\"hostname\":\"{s}\"}}\n",
            .{ pid, std.Io.Timestamp.now(io, .real).toMilliseconds(), "/definitely/not/agit", hostname },
        ) catch unreachable;
        try f.writeStreamingAll(io, line);
    }

    var lock = try LockFile.acquire(io, tmp.dir, "wrong-exe.lock", .{ .timeout_ms = 1_000 });
    lock.release(io);
}

test "lock timeout on live owner" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const pid = currentPid();
    {
        const f = try tmp.dir.createFile(io, "held.lock", .{});
        defer f.close(io);
        var line_buf: [1024]u8 = undefined;
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe = try currentExePathInto(io, &exe_buf);
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = currentHostNameInto(&host_buf);
        const line = std.fmt.bufPrint(
            &line_buf,
            "{{\"pid\":{d},\"started_at\":{d},\"exe_path\":\"{s}\",\"hostname\":\"{s}\"}}\n",
            .{ pid, std.Io.Timestamp.now(io, .real).toMilliseconds(), exe, hostname },
        ) catch unreachable;
        try f.writeStreamingAll(io, line);
    }

    const result = LockFile.acquire(io, tmp.dir, "held.lock", .{
        .timeout_ms = 30,
        .initial_delay_ms = 5,
        .max_delay_ms = 10,
    });
    try std.testing.expectError(error.LockTimeout, result);
}

test "non-contention acquire errors propagate" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const result = LockFile.acquire(io, tmp.dir, "missing-parent/test.lock", .{ .timeout_ms = 1_000 });
    try std.testing.expectError(error.FileNotFound, result);
}

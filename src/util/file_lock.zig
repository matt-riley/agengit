const std = @import("std");
const builtin = @import("builtin");

/// Cooperative advisory lock backed by a lock file.
///
/// Protocol:
/// 1. Create the lock file with exclusive=true (atomic O_CREAT|O_EXCL) and write the owner PID.
/// 2. On contention, read the PID and check if the process is still alive.
///    - POSIX: kill(pid, 0) — returns ESRCH when process is dead (stale lock).
///    - Windows: timeout-only (stale-lock reclaim deferred until std bindings are available).
/// 3. Stale lock: delete and re-acquire.
/// 4. Live lock: retry with exponential backoff until timeout_ms is exceeded.
/// 5. Unlock: delete the lock file.
pub const LockFile = struct {
    dir: std.Io.Dir,
    sub_path_buf: [std.fs.max_path_bytes]u8 = undefined,
    sub_path_len: usize = 0,

    pub const Options = struct {
        timeout_ms: i64 = 5_000,
        initial_delay_ms: i64 = 5,
        max_delay_ms: i64 = 250,
    };

    pub const AcquireError = error{
        LockTimeout,
        SubPathTooLong,
        Canceled,
    } || std.Io.File.OpenError || std.Io.Dir.DeleteFileError;

    /// Acquire the lock at dir/sub_path, blocking up to opts.timeout_ms milliseconds.
    pub fn acquire(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, opts: Options) AcquireError!LockFile {
        if (sub_path.len >= std.fs.max_path_bytes) return error.SubPathTooLong;

        var self: LockFile = .{ .dir = dir };
        @memcpy(self.sub_path_buf[0..sub_path.len], sub_path);
        self.sub_path_len = sub_path.len;

        const clock = std.Io.Clock.awake;
        const start = std.Io.Timestamp.now(io, clock);
        const timeout_dur = std.Io.Duration.fromMilliseconds(opts.timeout_ms);
        const deadline = start.addDuration(timeout_dur);
        var delay_ms = opts.initial_delay_ms;

        while (true) {
            switch (tryAcquireOnce(io, dir, sub_path)) {
                .acquired => return self,
                .contended => |maybe_pid| {
                    if (maybe_pid) |pid| {
                        if (!isProcessAlive(pid)) {
                            dir.deleteFile(io, sub_path) catch {};
                            switch (tryAcquireOnce(io, dir, sub_path)) {
                                .acquired => return self,
                                .contended => {},
                            }
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
        const sub_path = self.sub_path_buf[0..self.sub_path_len];
        self.dir.deleteFile(io, sub_path) catch {};
        self.sub_path_len = 0;
    }
};

const TryResult = union(enum) {
    acquired,
    contended: ?OsPid,
};

const OsPid = if (builtin.os.tag == .windows) u32 else std.posix.pid_t;

fn tryAcquireOnce(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) TryResult {
    const file = dir.createFile(io, sub_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return .{ .contended = readLockPid(io, dir, sub_path) },
        else => return .{ .contended = null },
    };
    defer file.close(io);

    const pid = currentPid();
    var pid_buf: [32]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{pid}) catch return .{ .contended = null };
    file.writeStreamingAll(io, pid_str) catch {};

    return .acquired;
}

fn readLockPid(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ?OsPid {
    var content_buf: [32]u8 = undefined;
    const file = dir.openFile(io, sub_path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, &content_buf, 0) catch return null;
    const text = std.mem.trim(u8, content_buf[0..n], "\n\r ");
    return std.fmt.parseInt(OsPid, text, 10) catch null;
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

test "acquire and release lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    var lock = try LockFile.acquire(io, tmp.dir, "test.lock", .{ .timeout_ms = 1_000 });
    defer lock.release(io);

    const err = LockFile.acquire(io, tmp.dir, "test.lock", .{ .timeout_ms = 50 });
    try std.testing.expectError(error.LockTimeout, err);
}

test "stale lock is reclaimed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    {
        const f = try tmp.dir.createFile(io, "stale.lock", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "0\n");
    }

    var lock = try LockFile.acquire(io, tmp.dir, "stale.lock", .{ .timeout_ms = 1_000 });
    lock.release(io);
}

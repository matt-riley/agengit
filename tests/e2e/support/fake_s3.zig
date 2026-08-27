const std = @import("std");

pub const Server = struct {
    child: std.process.Child,
    gpa: std.mem.Allocator,
    io: std.Io,
    endpoint: []u8,
    storage_root: []u8,
    ready_file: []u8,

    pub fn start(gpa: std.mem.Allocator, io: std.Io, base_root: []const u8) !Server {
        const storage_root = try std.fmt.allocPrint(gpa, "{s}/fake-s3", .{base_root});
        errdefer gpa.free(storage_root);
        const ready_file = try std.fmt.allocPrint(gpa, "{s}/fake-s3.port", .{base_root});
        errdefer gpa.free(ready_file);
        try std.Io.Dir.cwd().createDirPath(io, storage_root);

        var script_buf: [std.fs.max_path_bytes]u8 = undefined;
        const script_len = try std.Io.Dir.cwd().realPathFile(io, "tests/e2e/support/fake_s3_server.py", &script_buf);
        const script_path = script_buf[0..script_len];

        var child = try std.process.spawn(io, .{
            .argv = &.{ "/usr/bin/env", "python3", script_path, storage_root, ready_file },
            .stdin = .ignore,
            .stdout = .ignore,
            // Inherited rather than piped: nothing drains the pipe, and an
            // unread pipe hides interpreter failures forever. A healthy
            // server prints nothing, so there is no log noise either way.
            .stderr = .inherit,
            .create_no_window = true,
        });
        // kill() blocks until the child exits and reaps it; calling wait()
        // afterwards would trip Child.wait's assertion.
        errdefer child.kill(io);

        const endpoint = try waitForReady(gpa, io, ready_file, &child);

        return .{
            .child = child,
            .gpa = gpa,
            .io = io,
            .endpoint = endpoint,
            .storage_root = storage_root,
            .ready_file = ready_file,
        };
    }

    pub fn deinit(self: *Server) void {
        self.child.kill(self.io);
        self.gpa.free(self.endpoint);
        self.gpa.free(self.storage_root);
        self.gpa.free(self.ready_file);
        self.* = undefined;
    }
};

/// Polls for the port file written by the server once it binds. Deadline-based
/// rather than capped by iteration count: timer slippage under a heavily
/// loaded test runner must not shorten the ready window.
///
/// 45s rather than something tighter: on fresh GitHub-hosted macOS runners,
/// the first exec of a freshly-booted VM's python3 can be held up for many
/// seconds by Gatekeeper/codesign checks before the interpreter even starts
/// running the script, well before the server binds a port. That's dead time
/// unrelated to test-runner load, so the deadline has to absorb it.
fn waitForReady(gpa: std.mem.Allocator, io: std.Io, ready_file: []const u8, child: *std.process.Child) ![]u8 {
    const started = std.Io.Timestamp.now(io, .real);
    while (started.untilNow(io, .real).toMilliseconds() < 45_000) {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, ready_file, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (contents) |text| {
            defer gpa.free(text);
            const port = std.fmt.parseUnsigned(u16, std.mem.trim(u8, text, " \r\n"), 10) catch return error.InvalidReadyFile;
            return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
        }

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(25), .awake) catch {};
    }
    // Report the child's final liveness state so a timeout is diagnosable
    // from CI logs alone, without needing to reproduce locally.
    if (child.id) |pid| {
        const pid_text = try std.fmt.allocPrint(gpa, "{d}", .{pid});
        const ps = std.process.run(gpa, io, .{ .argv = &.{ "/bin/ps", "-o", "state,pid,ppid,etime,command", "-p", pid_text } }) catch null;
        if (ps) |res| {
            defer gpa.free(res.stdout);
            defer gpa.free(res.stderr);
            std.debug.print("[fs3] TIMEOUT after pid={d} ready_file={s}\n[fs3]   term={any}\n[fs3]   stdout: {s}\n[fs3]   stderr: {s}\n", .{
                pid,
                ready_file,
                res.term,
                res.stdout,
                res.stderr,
            });
        } else {
            std.debug.print("[fs3] TIMEOUT after spawn; ps probe failed to run\n", .{});
        }
    } else {
        std.debug.print("[fs3] TIMEOUT but child already reaped (id == null)\n", .{});
    }
    return error.FakeServerTimeout;
}

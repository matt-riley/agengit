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
            .stderr = .pipe,
            .create_no_window = true,
        });
        errdefer {
            child.kill(io);
            _ = child.wait(io) catch {};
        }

        const endpoint = waitForReady(gpa, io, ready_file, &child) catch |err| {
            child.kill(io);
            _ = child.wait(io) catch {};
            return err;
        };

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

fn waitForReady(gpa: std.mem.Allocator, io: std.Io, ready_file: []const u8, _: *std.process.Child) ![]u8 {
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, ready_file, gpa, .unlimited) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (contents) |text| {
            defer gpa.free(text);
            const port = std.fmt.parseUnsigned(u16, std.mem.trim(u8, text, " \r\n"), 10) catch return error.InvalidReadyFile;
            return std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}", .{port});
        }

        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }
    return error.FakeServerTimeout;
}

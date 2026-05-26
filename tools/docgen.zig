const std = @import("std");
const docgen = @import("cli_docgen");

const Mode = enum {
    write,
    check,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buf);

    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next();

    const mode = parseMode(&iter, &stdout, &stderr) catch |err| switch (err) {
        error.HelpShown => {
            try stdout.flush();
            return;
        },
        else => {
            try stderr.flush();
            return err;
        },
    };

    const ok = try run(init.io, std.Io.Dir.cwd(), init.gpa, mode, &stderr);
    try stderr.flush();
    if (!ok) std.process.exit(1);
}

fn parseMode(
    iter: *std.process.Args.Iterator,
    stdout: *std.Io.File.Writer,
    stderr: *std.Io.File.Writer,
) !Mode {
    var mode: Mode = .write;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            mode = .check;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try stdout.interface.writeAll(
                \\USAGE:
                \\    docgen [--check]
                \\
                \\OPTIONS:
                \\    --check    Fail if README.md's generated command section is stale.
                \\    -h, --help Display this help and exit.
                \\
            );
            return error.HelpShown;
        } else {
            try stderr.interface.print("error: unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    return mode;
}

fn run(
    io: std.Io,
    root: std.Io.Dir,
    gpa: std.mem.Allocator,
    mode: Mode,
    stderr: *std.Io.File.Writer,
) !bool {
    const current = try root.readFileAlloc(io, "README.md", gpa, .unlimited);
    defer gpa.free(current);

    const section = try docgen.renderCommandSection(gpa);
    defer gpa.free(section);

    const rewritten = try docgen.rewriteBetweenMarkers(gpa, current, section);
    defer gpa.free(rewritten);

    const changed = !std.mem.eql(u8, current, rewritten);
    switch (mode) {
        .write => {
            if (!changed) return true;
            var file = try root.createFile(io, "README.md", .{ .truncate = true });
            defer file.close(io);
            try file.writeStreamingAll(io, rewritten);
            return true;
        },
        .check => {
            if (!changed) return true;
            try stderr.interface.writeAll(
                "error: README generated command section is stale; run `zig build docgen`.\n",
            );
            return false;
        },
    }
}

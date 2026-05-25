const std = @import("std");
const store_mod = @import("../store/store.zig");
const exe_path_mod = @import("../util/exe_path.zig");

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: std.process.Environ,
    iter: *std.process.Args.Iterator,
) !void {
    _ = iter;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const home = environ.getPosix("HOME") orelse return error.MissingHOME;
    const exe = try exe_path_mod.getAlloc(io, gpa);
    defer gpa.free(exe);

    // --- Store check ---
    var store = store_mod.Store.open(io, std.Io.Dir.cwd(), gpa) catch |err| {
        try stdout.interface.print("  ✗ .agit/ store: {s}\n", .{@errorName(err)});
        try stdout.flush();
        return;
    };
    defer store.deinit(io);
    try stdout.interface.writeAll("  ✓ .agit/ store: ok\n");

    // --- Agent checks ---
    try checkAgent(io, gpa, home, exe, "claude", ".claude/settings.json", &stdout);
    try checkAgent(io, gpa, home, exe, "codex", ".codex/hooks.json", &stdout);
    try checkAgent(io, gpa, home, exe, "gemini", ".gemini/settings.json", &stdout);

    try stdout.flush();
}

fn detectBinary(io: std.Io, gpa: std.mem.Allocator, name: []const u8) bool {
    const result = std.process.run(gpa, io, .{ .argv = &.{ "which", name } }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn checkAgent(
    io: std.Io,
    gpa: std.mem.Allocator,
    home: []const u8,
    exe: []const u8,
    agent_name: []const u8,
    rel_config: []const u8,
    stdout: *std.Io.File.Writer,
) !void {
    const has_bin = detectBinary(io, gpa, agent_name);
    if (!has_bin) {
        try stdout.interface.print("  - {s}: not installed\n", .{agent_name});
        return;
    }
    try stdout.interface.print("  ✓ {s}: binary found\n", .{agent_name});

    const config_path = try std.mem.concat(gpa, u8, &.{ home, "/", rel_config });
    defer gpa.free(config_path);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const text = (readFileAllocOrNull(io, aa, config_path) catch null) orelse {
        try stdout.interface.print("  ✗ {s}: config not found ({s})\n", .{ agent_name, config_path });
        return;
    };

    const root_val = std.json.parseFromSliceLeaky(std.json.Value, aa, text, .{
        .allocate = .alloc_always,
    }) catch {
        try stdout.interface.print("  ✗ {s}: config not valid JSON ({s})\n", .{ agent_name, config_path });
        return;
    };

    if (root_val != .object) {
        try stdout.interface.print("  ✗ {s}: config root is not an object\n", .{agent_name});
        return;
    }

    const agit = root_val.object.get("_agit");
    if (agit == null or agit.? != .object) {
        try stdout.interface.print("  ✗ {s}: agit not initialized (no _agit metadata)\n", .{agent_name});
        return;
    }

    const bin_val = agit.?.object.get("binary");
    if (bin_val == null or bin_val.? != .string) {
        try stdout.interface.print("  ✗ {s}: _agit.binary missing\n", .{agent_name});
        return;
    }

    const stored = bin_val.?.string;
    if (std.mem.eql(u8, stored, exe)) {
        try stdout.interface.print("  ✓ {s}: hooks configured (binary matches)\n", .{agent_name});
    } else {
        try stdout.interface.print(
            "  ✗ {s}: binary mismatch (config has {s}, current is {s})\n",
            .{ agent_name, stored, exe },
        );
    }
}

fn readFileAllocOrNull(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size == 0) return null;

    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

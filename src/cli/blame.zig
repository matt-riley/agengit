const std = @import("std");
const store_mod = @import("../store/store.zig");
const hash_mod = @import("../store/hash.zig");
const snapshot_mod = @import("../store/snapshot.zig");
const file_limits_mod = @import("../util/file_limits.zig");
const status = @import("status.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");

pub const usage = specs.blame_usage;

const Options = struct {
    format: output_mod.Format = .human,
    no_limits: bool = false,
    step: ?[:0]const u8 = null,
    file_path: ?[:0]const u8 = null,
};

const RenderedLine = struct {
    step: []const u8,
    origin: []const u8,
    model: ?[]const u8 = null,
    timestamp: i64,
    text: []const u8,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    var opts: Options = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(&stdout, usage);
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.format = .json;
        } else if (std.mem.eql(u8, arg, "--no-limits")) {
            opts.no_limits = true;
        } else if (std.mem.eql(u8, arg, "--step")) {
            opts.step = iter.next();
        } else if (opts.file_path == null) {
            opts.file_path = arg;
        }
    }

    const file_path = opts.file_path orelse {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    };

    var store = try status.openStoreOrExit(io, gpa, &stdout, opts.format, usage.name);
    defer store.deinit(io);

    // Resolve the blame row: latest, or as-of the selected step.
    const row = blk: {
        if (opts.step) |step_prefix| {
            const step_hex = try resolveStepHex(io, gpa, &store, &stdout, opts.format, step_prefix);
            defer gpa.free(step_hex);
            const step_hash = try hash_mod.Hash.fromHex(step_hex);
            var parsed = store.readStep(io, gpa, step_hash) catch {
                try diag(&stdout, opts.format, .{
                    .code = "step_not_found",
                    .message = "Could not read the requested step object.",
                    .hash = step_prefix,
                });
                try stdout.flush();
                std.process.exit(1);
            };
            defer parsed.deinit();
            break :blk try store.index.queryBlameAtStep(file_path, parsed.value.timestamp, step_hex);
        }
        break :blk try store.index.queryLatestBlame(file_path);
    } orelse {
        try diag(&stdout, opts.format, .{
            .code = "no_blame",
            .message = "No blame recorded for this path.",
            .hint = "Blame is recorded as agents change files; run `agit reindex` if the index was rebuilt.",
            .path = file_path,
        });
        try stdout.flush();
        std.process.exit(1);
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Load the blame map and the snapshot content it describes.
    const blame_parsed = try store.readBlame(io, arena, try hash_mod.Hash.fromHex(row.blame_hash[0..]));
    const blame_map = blame_parsed.value;

    const content = try store.readBlob(io, arena, try hash_mod.Hash.fromHex(row.blob_hash[0..]));
    if (!opts.no_limits and content.len > file_limits_mod.effectiveMaxFileBytes(16 * 1024 * 1024)) {
        try diag(&stdout, opts.format, .{
            .code = "file_too_large",
            .message = "File exceeds the blame size cap.",
            .hint = "Pass --no-limits to render blame for this file anyway.",
            .path = file_path,
        });
        try stdout.flush();
        std.process.exit(1);
    }
    const lines = try snapshot_mod.splitLines(arena, content);

    // Attribution lines come from the blame map; if it diverges from the stored
    // content (should not happen) fall back to the shorter length.
    const count = @min(lines.len, blame_map.lines.len);
    var rendered = try arena.alloc(RenderedLine, count);
    for (0..count) |i| {
        const step_hex = blame_map.lines[i].step;
        const meta = try store.index.queryStepMeta(arena, step_hex);
        rendered[i] = .{
            .step = step_hex,
            .origin = if (meta) |m| m.origin else "unknown",
            .model = if (meta) |m| m.model else null,
            .timestamp = if (meta) |m| m.timestamp else 0,
            .text = lines[i],
        };
    }

    switch (opts.format) {
        .human => try writeHuman(&stdout, file_path, rendered),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .path = file_path,
            .lines = rendered,
        }),
    }
    try stdout.flush();
}

fn writeHuman(stdout: *std.Io.File.Writer, file_path: []const u8, rendered: []const RenderedLine) !void {
    try stdout.interface.print("blame {s}\n\n", .{file_path});
    var ts_buf: [32]u8 = undefined;
    for (rendered, 0..) |line, i| {
        const ts = status.formatTimestamp(line.timestamp, &ts_buf);
        const actor = line.model orelse line.origin;
        try stdout.interface.print("{s}  {s:<16}  {s}  {d:>5}  {s}\n", .{
            line.step[0..@min(12, line.step.len)],
            actor,
            ts,
            i + 1,
            line.text,
        });
    }
}

fn resolveStepHex(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *store_mod.Store,
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    prefix: [:0]const u8,
) ![]u8 {
    const resolution = store.resolvePrefix(io, gpa, prefix) catch |err| {
        try diag(stdout, format, .{
            .code = "object_lookup_failed",
            .message = "Failed to resolve step prefix.",
            .hint = @errorName(err),
            .hash = prefix,
        });
        try stdout.flush();
        std.process.exit(1);
    };
    switch (resolution) {
        .not_found => {
            try diag(stdout, format, .{
                .code = "step_not_found",
                .message = "Step not found.",
                .hint = "Use a longer or different hash prefix.",
                .hash = prefix,
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .ambiguous => {
            try diag(stdout, format, .{
                .code = "ambiguous_hash_prefix",
                .message = "Hash prefix is ambiguous.",
                .hint = "Use a longer hash prefix.",
                .hash = prefix,
            });
            try stdout.flush();
            std.process.exit(1);
        },
        .unique => |resolved| {
            const hex = resolved.toHex();
            return gpa.dupe(u8, hex[0..]);
        },
    }
}

fn diag(stdout: *std.Io.File.Writer, format: output_mod.Format, d: output_mod.Diagnostic) !void {
    try status.writeDiagnostic(stdout, format, usage.name, d);
}

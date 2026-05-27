const std = @import("std");

const bundle_mod = @import("../store/bundle.zig");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");

pub const usage = specs.import_usage;

const Options = struct {
    format: output_mod.Format = .human,
    path: ?[]const u8 = null,
    replace_refs: std.ArrayList(bundle_mod.SessionFilter) = .empty,

    fn deinit(self: *Options, gpa: std.mem.Allocator) void {
        self.replace_refs.deinit(gpa);
        self.* = undefined;
    }
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    var options = parseOptions(gpa, iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => return err,
    };
    defer options.deinit(gpa);

    const bundle_path = options.path orelse {
        try invalidArgument(&stdout, options.format, "import requires a bundle directory path.");
        return;
    };

    var store = try status_cmd.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
    defer store.deinit(io);

    const result = bundle_mod.importBundle(io, gpa, &store, .{
        .path = bundle_path,
        .replace_refs = options.replace_refs.items,
    }) catch |err| {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "import_failed",
            .message = "Failed to import the portable bundle.",
            .hint = @errorName(err),
            .path = bundle_path,
        });
        try stdout.flush();
        std.process.exit(1);
    };

    const reconcile = try store.reconcile(io, gpa, .repair);

    switch (options.format) {
        .human => try stdout.interface.print(
            "import: path={s} bundle={s} imported_objects={d} skipped_objects={d} cloned_steps={d} created_refs={d} replaced_refs={d} namespaced_refs={d} unchanged_refs={d} reconciled={d}\n",
            .{
                bundle_path,
                result.bundle_id[0..12],
                result.imported_objects,
                result.skipped_objects,
                result.cloned_steps,
                result.created_refs,
                result.replaced_refs,
                result.namespaced_refs,
                result.unchanged_refs,
                reconcile.repaired,
            },
        ),
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .path = bundle_path,
            .bundle_id = result.bundle_id[0..],
            .imported_objects = result.imported_objects,
            .skipped_objects = result.skipped_objects,
            .cloned_steps = result.cloned_steps,
            .created_refs = result.created_refs,
            .replaced_refs = result.replaced_refs,
            .namespaced_refs = result.namespaced_refs,
            .unchanged_refs = result.unchanged_refs,
            .reconcile = reconcile,
        }),
    }
    try stdout.flush();
}

fn parseOptions(
    gpa: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
    stdout: *std.Io.File.Writer,
) !Options {
    var options: Options = .{};
    errdefer options.deinit(gpa);

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--replace-ref")) {
            const value = iter.next() orelse {
                try invalidArgument(stdout, options.format, "--replace-ref requires an origin/session-id value.");
                return error.InvalidArgument;
            };
            const session = parseSessionSpec(value) catch {
                try invalidArgument(stdout, options.format, "Invalid --replace-ref value; use origin/session-id.");
                return error.InvalidArgument;
            };
            try options.replace_refs.append(gpa, session);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try invalidArgument(stdout, options.format, "Unknown option.");
            return error.InvalidArgument;
        } else if (options.path == null) {
            options.path = arg;
        } else {
            try invalidArgument(stdout, options.format, "import accepts only one bundle directory path.");
            return error.InvalidArgument;
        }
    }

    return options;
}

fn parseSessionSpec(raw: []const u8) !bundle_mod.SessionFilter {
    const sep = std.mem.indexOfScalar(u8, raw, '/') orelse return error.InvalidSession;
    if (sep == 0 or sep + 1 >= raw.len) return error.InvalidSession;
    return .{
        .origin = raw[0..sep],
        .session_id = raw[sep + 1 ..],
    };
}

fn invalidArgument(stdout: *std.Io.File.Writer, format: output_mod.Format, message: []const u8) !void {
    try status_cmd.writeDiagnostic(stdout, format, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    if (format == .human) {
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(stdout, usage);
    }
    try stdout.flush();
    std.process.exit(1);
}

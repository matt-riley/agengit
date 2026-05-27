const std = @import("std");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const specs = @import("specs.zig");
const status_cmd = @import("status.zig");
const observer_source_mod = @import("../observer/Source.zig");
const observer_checkpoint_mod = @import("../observer/checkpoint.zig");
const observer_runner_mod = @import("../observer/runner.zig");
const observer_registry = @import("../observer/sources/registry.zig");
const recorder_mod = @import("../recorder.zig");

pub const usage = specs.observe_usage;

const ObserveOptions = struct {
    format: output_mod.Format = .human,
    once: bool = false,
    input_path: ?[]const u8 = null,
    source_name: ?[]const u8 = null,
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const options = parseOptions(iter, &stdout) catch |err| switch (err) {
        error.HelpShown => return,
        else => {
            try writeRunError(&stdout, .human, "", err);
            try stdout.interface.writeAll("\n");
            try help_mod.renderUsage(&stdout, usage);
            try stdout.flush();
            std.process.exit(1);
        },
    };

    const source_name = options.source_name orelse {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "missing_source",
            .message = "Missing observer source name.",
            .hint = "Pass a source such as `fixture`.",
        });
        if (options.format == .human) {
            try stdout.interface.writeAll("\n");
            try help_mod.renderUsage(&stdout, usage);
        }
        try stdout.flush();
        std.process.exit(1);
    };

    const source = observer_registry.find(source_name) orelse {
        try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
            .code = "unknown_source",
            .message = "Unknown observer source.",
            .hint = source_name,
            .candidates = sourceNames(),
        });
        if (options.format == .human) {
            try stdout.interface.writeAll("\n");
            try help_mod.renderUsage(&stdout, usage);
        }
        try stdout.flush();
        std.process.exit(1);
    };

    var recorder = recorder_mod.Recorder.open(io, std.Io.Dir.cwd(), gpa) catch |err| switch (err) {
        error.StoreNotFound => {
            try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
                .code = "store_not_found",
                .message = "Not an agit repository.",
                .hint = "Run `agit init` from the repository root to start recording.",
                .path = ".",
            });
            try stdout.flush();
            std.process.exit(1);
        },
        else => {
            try status_cmd.writeDiagnostic(&stdout, options.format, usage.name, .{
                .code = "observe_open_failed",
                .message = "Failed to open the agit recorder.",
                .hint = @errorName(err),
                .path = ".",
            });
            try stdout.flush();
            std.process.exit(1);
        },
    };
    defer recorder.deinit(io);

    const summary = observer_runner_mod.runOnce(io, gpa, &recorder, source, .{
        .input_path = options.input_path,
    }) catch |err| {
        try writeRunError(&stdout, options.format, source.name, err);
        if (options.format == .human) {
            try stdout.interface.writeAll("\n");
            try help_mod.renderUsage(&stdout, usage);
        }
        try stdout.flush();
        std.process.exit(1);
    };

    var checkpoint_buf: [128]u8 = undefined;
    const checkpoint_rel = try observer_checkpoint_mod.relativePath(&checkpoint_buf, source.name);
    var checkpoint_display_buf: [160]u8 = undefined;
    const checkpoint_display = try std.fmt.bufPrint(&checkpoint_display_buf, ".agit/{s}", .{checkpoint_rel});

    switch (options.format) {
        .human => {
            try stdout.interface.print(
                "observe: processed {d} event(s) from {s}{s}\n",
                .{
                    summary.processed_events,
                    if (source.experimental) "experimental " else "",
                    source.name,
                },
            );
            try stdout.interface.print(
                "  prompts={d} tool_calls={d} finalized_turns={d} skipped_disabled={d}\n",
                .{
                    summary.prompts,
                    summary.tool_calls,
                    summary.finalized_turns,
                    summary.skipped_disabled_events,
                },
            );
            try stdout.interface.print("  checkpoint={s}\n", .{checkpoint_display});
            if (!options.once) {
                try stdout.interface.writeAll("  note: current observer sources run one pass and exit; use --once for explicit scripting.\n");
            }
        },
        .json => try output_mod.writeEnvelope(&stdout, usage.name, .{
            .source = source.name,
            .experimental = source.experimental,
            .processed_events = summary.processed_events,
            .prompts = summary.prompts,
            .tool_calls = summary.tool_calls,
            .finalized_turns = summary.finalized_turns,
            .skipped_disabled_events = summary.skipped_disabled_events,
            .checkpoint = checkpoint_display,
        }),
    }
    try stdout.flush();
}

fn parseOptions(iter: *std.process.Args.Iterator, stdout: *std.Io.File.Writer) !ObserveOptions {
    var options: ObserveOptions = .{};
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            options.format = .json;
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else if (std.mem.eql(u8, arg, "--input")) {
            options.input_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try help_mod.renderUsage(stdout, usage);
            try stdout.flush();
            return error.HelpShown;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try status_cmd.writeDiagnostic(stdout, options.format, usage.name, .{
                .code = "invalid_argument",
                .message = "Unknown option.",
                .hint = arg,
            });
            try stdout.flush();
            std.process.exit(1);
        } else if (options.source_name == null) {
            options.source_name = arg;
        } else {
            try status_cmd.writeDiagnostic(stdout, options.format, usage.name, .{
                .code = "invalid_argument",
                .message = "Unexpected argument.",
                .hint = arg,
            });
            try stdout.flush();
            std.process.exit(1);
        }
    }
    return options;
}

fn writeRunError(
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    source_name: []const u8,
    err: anyerror,
) !void {
    const diagnostic = switch (err) {
        error.MissingOptionValue => output_mod.Diagnostic{
            .code = "missing_option_value",
            .message = "Missing value for --input.",
            .hint = "--input <PATH>",
        },
        error.ObserverInputRequired => output_mod.Diagnostic{
            .code = "missing_input",
            .message = "The selected observer source requires --input.",
            .hint = source_name,
        },
        error.ObserverInputTooLarge => output_mod.Diagnostic{
            .code = "input_too_large",
            .message = "Observer input exceeds the 4 MiB safety cap.",
            .hint = "Trim the fixture or split it into smaller batches.",
        },
        error.ObserverCheckpointInstanceMismatch => output_mod.Diagnostic{
            .code = "checkpoint_instance_mismatch",
            .message = "Existing observer checkpoint belongs to a different input path.",
            .hint = "Delete .agit/observers/<source>.json if you intentionally changed inputs.",
        },
        error.ObserverWatermarkNotFound => output_mod.Diagnostic{
            .code = "watermark_not_found",
            .message = "Stored observer watermark is missing from the current input.",
            .hint = "Restore the older events or reset the observer checkpoint.",
        },
        error.InvalidObserverCheckpoint => output_mod.Diagnostic{
            .code = "invalid_checkpoint",
            .message = "Observer checkpoint JSON is malformed.",
            .hint = "Fix or remove .agit/observers/<source>.json before retrying.",
        },
        error.UnsupportedObserverCheckpointVersion => output_mod.Diagnostic{
            .code = "unsupported_checkpoint_version",
            .message = "Observer checkpoint version is not supported.",
        },
        error.DuplicateObserverWatermark => output_mod.Diagnostic{
            .code = "duplicate_watermark",
            .message = "Observer input reuses the same watermark more than once.",
        },
        error.InvalidObserverEvent => output_mod.Diagnostic{
            .code = "invalid_observer_event",
            .message = "Observer input contains an invalid event payload.",
        },
        else => output_mod.Diagnostic{
            .code = "observe_failed",
            .message = "Observer run failed.",
            .hint = @errorName(err),
        },
    };
    try status_cmd.writeDiagnostic(stdout, format, usage.name, diagnostic);
}

fn sourceNames() []const []const u8 {
    return &source_names;
}

const source_names = blk: {
    var names: [observer_registry.all.len][]const u8 = undefined;
    for (observer_registry.all, 0..) |source, index| {
        names[index] = source.name;
    }
    break :blk names;
};

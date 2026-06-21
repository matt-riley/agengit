const std = @import("std");
const help_mod = @import("help.zig");
const output_mod = @import("output.zig");
const status = @import("status.zig");

pub fn invalidArg(
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    usage: help_mod.UsageSpec,
    message: []const u8,
) !void {
    try status.writeDiagnostic(stdout, format, usage.name, .{
        .code = "invalid_argument",
        .message = message,
    });
    if (format == .human) {
        try stdout.interface.writeAll("\n");
        try help_mod.renderUsage(stdout, usage);
    }
    try stdout.flush();
}

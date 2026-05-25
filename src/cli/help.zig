const std = @import("std");

pub const Option = struct {
    long: ?[]const u8 = null,
    short: ?u8 = null,
    value_name: ?[]const u8 = null,
    description: []const u8,
    repeatable: bool = false,
    value_choices: []const []const u8 = &.{},
};

pub const Example = struct {
    description: []const u8,
    command: []const u8,
};

pub const UsageSpec = struct {
    name: []const u8,
    synopsis: []const u8,
    description: []const u8,
    options: []const Option = &.{},
    examples: []const Example = &.{},
    notes: []const u8 = "",
};

pub const CommandSpec = struct {
    name: []const u8,
    summary: []const u8,
    usage: ?*const UsageSpec = null,
};

pub fn renderUsage(w: anytype, spec: UsageSpec) !void {
    try w.interface.print("USAGE:\n    agit {s} {s}\n\n", .{ spec.name, spec.synopsis });

    if (spec.description.len > 0) {
        try w.interface.print("DESCRIPTION:\n    {s}\n\n", .{spec.description});
    }

    if (spec.options.len > 0) {
        try w.interface.print("OPTIONS:\n", .{});
        for (spec.options) |opt| {
            try renderOption(w, opt);
        }
        try w.interface.print("\n", .{});
    }

    if (spec.examples.len > 0) {
        try w.interface.print("EXAMPLES:\n", .{});
        for (spec.examples) |ex| {
            try w.interface.print("    # {s}\n", .{ex.description});
            if (ex.command.len > 0) {
                try w.interface.print("    agit {s} {s}\n", .{ spec.name, ex.command });
            } else {
                try w.interface.print("    agit {s}\n", .{spec.name});
            }
        }
        try w.interface.print("\n", .{});
    }

    if (spec.notes.len > 0) {
        try w.interface.print("NOTES:\n    {s}\n\n", .{spec.notes});
    }
}

pub fn renderTopLevelUsage(w: anytype, commands: []const CommandSpec) !void {
    try w.interface.writeAll(
        \\agit - AI agent version control
        \\
        \\Usage: agit [options] <command> [command-options]
        \\
        \\Options:
        \\  -h, --help     Display this help and exit.
        \\  -V, --version  Print version and exit.
        \\
        \\Commands:
        \\
    );
    for (commands) |command| {
        try w.interface.print("  {s:<13} {s}\n", .{ command.name, command.summary });
    }
    try w.interface.writeAll(
        \\
        \\Run 'agit <command> --help' for command-specific help.
        \\
    );
}

pub fn renderRepoNotFound(w: anytype, searched: []const u8) !void {
    var mutable_w = w;
    try mutable_w.print(
        \\error: not an agit repository
        \\
        \\Searched from: {s}
        \\
        \\To start recording, run:
        \\    agit init
        \\
    , .{searched});
}

pub fn renderEnvError(w: anytype, err: anyerror, ctx: []const u8) !void {
    var mutable_w = w;
    switch (err) {
        error.MissingHome => try mutable_w.print(
            \\error: $HOME environment variable not set or invalid
            \\
            \\Context: {s}
            \\
            \\Set $HOME to a valid directory and try again.
            \\
        , .{ctx}),
        else => try mutable_w.print(
            \\error: {s}
            \\
            \\Context: {s}
            \\
        , .{ @errorName(err), ctx }),
    }
}

pub fn findLongOption(spec: UsageSpec, long: []const u8) ?Option {
    for (spec.options) |opt| {
        if (opt.long) |opt_long| {
            if (std.mem.eql(u8, opt_long, long)) return opt;
        }
    }
    return null;
}

fn renderOption(w: anytype, opt: Option) !void {
    try w.interface.writeAll("    ");

    if (opt.short) |short| {
        try w.interface.print("-{c}", .{short});
        if (opt.long != null) try w.interface.writeAll(", ");
    }

    if (opt.long) |long| {
        try w.interface.print("--{s}", .{long});
    }

    if (opt.value_name) |value_name| {
        try w.interface.print(" <{s}>", .{value_name});
    }

    try w.interface.print("\n        {s}\n", .{opt.description});
}

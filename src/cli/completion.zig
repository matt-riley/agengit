const std = @import("std");
const help_mod = @import("help.zig");
const registry = @import("registry.zig");

pub const usage = help_mod.UsageSpec{
    .name = "completion",
    .synopsis = "[OPTIONS] <SHELL>",
    .description = "Generate shell completion scripts for bash, zsh, fish, or nushell.",
    .options = &.{
        .{ .short = 'h', .long = "help", .description = "Display this help and exit." },
    },
    .examples = &.{
        .{ .description = "bash completion script", .command = "bash" },
        .{ .description = "zsh completion script", .command = "zsh" },
        .{ .description = "fish completion script", .command = "fish" },
        .{ .description = "nushell completion script", .command = "nushell" },
    },
};

pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = gpa;

    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    var help_requested = false;
    var shell_name: ?[:0]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            help_requested = true;
        } else if (shell_name == null) {
            shell_name = arg;
        } else {
            try stdout.interface.print("error: unexpected argument '{s}'\n\n", .{arg});
            try help_mod.renderUsage(&stdout, usage);
            try stdout.flush();
            std.process.exit(1);
        }
    }

    if (help_requested) {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    }

    const shell = shell_name orelse {
        try help_mod.renderUsage(&stdout, usage);
        try stdout.flush();
        return;
    };

    if (std.mem.eql(u8, shell, "bash")) {
        try writeBash(&stdout);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try writeZsh(&stdout);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try writeFish(&stdout);
    } else if (std.mem.eql(u8, shell, "nushell")) {
        try writeNushell(&stdout);
    } else {
        try stdout.interface.print("error: unknown shell '{s}'\nshells: bash zsh fish nushell\n", .{shell});
        try stdout.flush();
        std.process.exit(1);
    }

    try stdout.flush();
}

fn writeBash(w: *std.Io.File.Writer) !void {
    try w.interface.writeAll(
        \\# agit bash completion
        \\_agit_complete() {
        \\    local cur prev cmd
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    cmd="${COMP_WORDS[1]}"
        \\
        \\    if [[ $COMP_CWORD -eq 1 ]]; then
        \\        COMPREPLY=($(compgen -W "
    );
    try writeBashTopLevelWords(w);
    try w.interface.writeAll(
        \\" -- "$cur"))
        \\        return 0
        \\    fi
        \\
        \\    case "$cmd" in
        \\
    );

    for (registry.public_commands) |command| {
        const spec = command.usage.?;
        try w.interface.print("    {s})\n", .{command.name});
        try writeBashChoiceHandlers(w, spec);
        try w.interface.writeAll("        COMPREPLY=($(compgen -W \"");
        try writeBashOptionWords(w, spec);
        try w.interface.writeAll("\" -- \"$cur\"))\n        ;;\n");
    }

    try w.interface.writeAll(
        \\    esac
        \\}
        \\complete -F _agit_complete agit
        \\
    );
}

fn writeZsh(w: *std.Io.File.Writer) !void {
    try w.interface.writeAll(
        \\#compdef agit
        \\_agit() {
        \\    local context state line
        \\    local -a commands
        \\    commands=(
        \\
    );
    for (registry.public_commands) |command| {
        try w.interface.print("        '{s}:{s}'\n", .{ command.name, command.summary });
    }
    try w.interface.writeAll(
        \\    )
        \\    _arguments -C \
        \\        '-h[Display this help and exit.]' \
        \\        '-V[Print version and exit.]' \
        \\        '1:command:->command' \
        \\        '*::arg:->args'
        \\
        \\    case $state in
        \\        command)
        \\            _describe 'agit command' commands
        \\            ;;
        \\        args)
        \\            case $words[2] in
        \\
    );

    for (registry.public_commands) |command| {
        try w.interface.print("                {s})\n", .{command.name});
        try w.interface.writeAll("                    _arguments");
        const spec = command.usage.?;
        for (spec.options) |opt| {
            try w.interface.writeAll(" \\\n                        '");
            try writeZshOptionSpec(w, opt);
            try w.interface.writeAll("'");
        }
        try w.interface.writeAll("\n                    ;;\n");
    }

    try w.interface.writeAll(
        \\            esac
        \\            ;;
        \\    esac
        \\}
        \\_agit "$@"
        \\
    );
}

fn writeFish(w: *std.Io.File.Writer) !void {
    try w.interface.writeAll(
        \\# agit fish completion
        \\complete -c agit -f
        \\complete -c agit -f -n '__fish_use_subcommand' -s h -l help -d 'Display this help and exit.'
        \\complete -c agit -f -n '__fish_use_subcommand' -s V -l version -d 'Print version and exit.'
        \\
    );

    for (registry.public_commands) |command| {
        try w.interface.print(
            "complete -c agit -f -n '__fish_use_subcommand' -a {s} -d '{s}'\n",
            .{ command.name, command.summary },
        );
    }
    try w.interface.writeAll("\n");

    for (registry.public_commands) |command| {
        const spec = command.usage.?;
        for (spec.options) |opt| {
            try w.interface.print("complete -c agit -f -n '__fish_seen_subcommand_from {s}'", .{command.name});
            if (opt.short) |short| {
                try w.interface.print(" -s {c}", .{short});
            }
            if (opt.long) |long| {
                try w.interface.print(" -l {s}", .{long});
            }
            if (opt.value_name != null) try w.interface.writeAll(" -r");
            if (opt.value_choices.len > 0) {
                try w.interface.writeAll(" -a '");
                for (opt.value_choices, 0..) |choice, i| {
                    if (i != 0) try w.interface.writeAll(" ");
                    try w.interface.writeAll(choice);
                }
                try w.interface.writeAll("'");
            }
            try w.interface.print(" -d '{s}'\n", .{opt.description});
        }
    }
}

fn writeNushell(w: *std.Io.File.Writer) !void {
    try w.interface.writeAll(
        \\# agit nushell completion
        \\def "nu-complete agit command" [] {
        \\    [
        \\
    );
    for (registry.public_commands) |command| {
        try w.interface.print("        {{ value: '{s}', description: '{s}' }}\n", .{ command.name, command.summary });
    }
    try w.interface.writeAll(
        \\    ]
        \\}
        \\
    );

    for (registry.public_commands) |command| {
        const spec = command.usage.?;
        for (spec.options) |opt| {
            if (opt.value_choices.len == 0) continue;
            if (opt.long) |long| {
                try w.interface.print("def \"nu-complete agit {s}-{s}\" [] {{\n    [", .{ command.name, long });
                for (opt.value_choices, 0..) |choice, i| {
                    if (i != 0) try w.interface.writeAll(", ");
                    try w.interface.print("'{s}'", .{choice});
                }
                try w.interface.writeAll("]\n}\n\n");
            }
        }
    }

    try w.interface.writeAll(
        \\extern "agit" [
        \\    command?: string@"nu-complete agit command"
        \\    ...args: string
        \\]
        \\
    );

    for (registry.public_commands) |command| {
        try w.interface.print("extern \"agit {s}\" [\n", .{command.name});
        const spec = command.usage.?;
        for (spec.options) |opt| {
            try w.interface.writeAll("    ");
            try writeNushellOptionSpec(w, command.name, opt);
            try w.interface.writeAll("\n");
        }
        try w.interface.writeAll("]\n\n");
    }
}

fn writeBashTopLevelWords(w: *std.Io.File.Writer) !void {
    try w.interface.writeAll("-h --help -V --version");
    for (registry.public_commands) |command| {
        try w.interface.print(" {s}", .{command.name});
    }
}

fn writeBashOptionWords(w: *std.Io.File.Writer, spec: *const help_mod.UsageSpec) !void {
    for (spec.options) |opt| {
        if (opt.short) |short| {
            try w.interface.print("-{c} ", .{short});
        }
        if (opt.long) |long| {
            try w.interface.print("--{s} ", .{long});
        }
    }
}

fn writeBashChoiceHandlers(w: *std.Io.File.Writer, spec: *const help_mod.UsageSpec) !void {
    for (spec.options) |opt| {
        if (opt.value_choices.len == 0) continue;
        if (opt.long) |long| {
            try w.interface.print("        if [[ \"$prev\" == \"--{s}\" ]]; then\n", .{long});
            try w.interface.writeAll("            COMPREPLY=($(compgen -W \"");
            for (opt.value_choices, 0..) |choice, i| {
                if (i != 0) try w.interface.writeAll(" ");
                try w.interface.writeAll(choice);
            }
            try w.interface.writeAll("\" -- \"$cur\"))\n            return 0\n        fi\n");
        }
        if (opt.short) |short| {
            try w.interface.print("        if [[ \"$prev\" == \"-{c}\" ]]; then\n", .{short});
            try w.interface.writeAll("            COMPREPLY=($(compgen -W \"");
            for (opt.value_choices, 0..) |choice, i| {
                if (i != 0) try w.interface.writeAll(" ");
                try w.interface.writeAll(choice);
            }
            try w.interface.writeAll("\" -- \"$cur\"))\n            return 0\n        fi\n");
        }
    }
}

fn writeZshOptionSpec(w: *std.Io.File.Writer, opt: help_mod.Option) !void {
    if (opt.long) |long| {
        try w.interface.print("--{s}", .{long});
    } else if (opt.short) |short| {
        try w.interface.print("-{c}", .{short});
    }

    try w.interface.print("[{s}]", .{opt.description});

    if (opt.value_name) |value_name| {
        try w.interface.print(":{s}", .{value_name});
        if (opt.value_choices.len > 0) {
            try w.interface.writeAll(":(");
            for (opt.value_choices, 0..) |choice, i| {
                if (i != 0) try w.interface.writeAll(" ");
                try w.interface.writeAll(choice);
            }
            try w.interface.writeAll(")");
        }
    }
}

fn writeNushellOptionSpec(w: *std.Io.File.Writer, command_name: []const u8, opt: help_mod.Option) !void {
    if (opt.long) |long| {
        try w.interface.print("--{s}", .{long});
        if (opt.short) |short| {
            try w.interface.print("(-{c})", .{short});
        }
    } else if (opt.short) |short| {
        try w.interface.print("-{c}", .{short});
    }

    if (opt.value_name != null) {
        try w.interface.writeAll(": string");
        if (opt.long) |long| {
            if (opt.value_choices.len > 0) {
                try w.interface.print("@\"nu-complete agit {s}-{s}\"", .{ command_name, long });
            }
        }
    }
}

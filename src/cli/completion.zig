const std = @import("std");

const bash_completion =
    \\# agit bash completion
    \\_agit_complete() {
    \\    local cur="${COMP_WORDS[COMP_CWORD]}"
    \\    local cmds="init uninstall doctor reindex status sessions log show blame cat completion version"
    \\    COMPREPLY=($(compgen -W "$cmds" -- "$cur"))
    \\}
    \\complete -F _agit_complete agit
    \\
;

const zsh_completion =
    \\#compdef agit
    \\_agit() {
    \\    local -a commands
    \\    commands=(
    \\        'init:install agit hooks'
    \\        'uninstall:remove agit hooks'
    \\        'doctor:check hook installation'
    \\        'reindex:rebuild the step index'
    \\        'status:show repository state'
    \\        'sessions:list recorded sessions'
    \\        'log:show step history'
    \\        'show:show a step object'
    \\        'blame:show file attribution'
    \\        'cat:print raw object bytes'
    \\        'completion:generate shell completion'
    \\        'version:print version'
    \\    )
    \\    _describe 'agit command' commands
    \\}
    \\_agit "$@"
    \\
;

const fish_completion =
    \\# agit fish completion
    \\complete -c agit -f -n '__fish_use_subcommand'
    \\complete -c agit -f -n '__fish_use_subcommand' -a init        -d 'install agit hooks'
    \\complete -c agit -f -n '__fish_use_subcommand' -a uninstall   -d 'remove agit hooks'
    \\complete -c agit -f -n '__fish_use_subcommand' -a doctor      -d 'check hook installation'
    \\complete -c agit -f -n '__fish_use_subcommand' -a reindex     -d 'rebuild the step index'
    \\complete -c agit -f -n '__fish_use_subcommand' -a status      -d 'show repository state'
    \\complete -c agit -f -n '__fish_use_subcommand' -a sessions    -d 'list recorded sessions'
    \\complete -c agit -f -n '__fish_use_subcommand' -a log         -d 'show step history'
    \\complete -c agit -f -n '__fish_use_subcommand' -a show        -d 'show a step object'
    \\complete -c agit -f -n '__fish_use_subcommand' -a blame       -d 'show file attribution'
    \\complete -c agit -f -n '__fish_use_subcommand' -a cat         -d 'print raw object bytes'
    \\complete -c agit -f -n '__fish_use_subcommand' -a completion  -d 'generate shell completion'
    \\complete -c agit -f -n '__fish_use_subcommand' -a version     -d 'print version'
    \\
;

const nushell_completion =
    \\# agit nushell completion
    \\def "nu-complete agit" [] {
    \\    ["init", "uninstall", "doctor", "reindex", "status", "sessions", "log", "show", "blame", "cat", "completion", "version"]
    \\}
    \\extern "agit" [
    \\    command: string@"nu-complete agit"
    \\    ...args: string
    \\]
    \\
;

// Phase 6 implementation: generate shell completion scripts (bash/zsh/fish/nushell).
pub fn run(io: std.Io, gpa: std.mem.Allocator, iter: *std.process.Args.Iterator) !void {
    _ = gpa;

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);

    const shell = iter.next() orelse {
        try stdout.interface.writeAll("usage: agit completion <shell>\nshells: bash zsh fish nushell\n");
        try stdout.flush();
        return;
    };

    const script: []const u8 = if (std.mem.eql(u8, shell, "bash"))
        bash_completion
    else if (std.mem.eql(u8, shell, "zsh"))
        zsh_completion
    else if (std.mem.eql(u8, shell, "fish"))
        fish_completion
    else if (std.mem.eql(u8, shell, "nushell"))
        nushell_completion
    else {
        try stdout.interface.print("error: unknown shell '{s}'\nshells: bash zsh fish nushell\n", .{shell});
        try stdout.flush();
        return;
    };

    try stdout.interface.writeAll(script);
    try stdout.flush();
}

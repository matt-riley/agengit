# ADR 012: Consistent CLI help and repo-discovery hints

**Status:** Proposed
**Date:** 2026-05-25

## Context

`agit` ships fifteen subcommands but only a handful have `--help` text or
helpful errors:

- `src/cli/cat.zig`, `show.zig`, `sessions.zig`, `log.zig`, `status.zig`,
  `blame.zig` all skip per-command help and either error on bad input or
  silently return.
- `status` and `show` print `Not an agit repository` without naming the
  searched path or suggesting `agit init`.
- `init` prints raw `error.FileNotFound` when `$HOME` or the parent of a
  managed config is missing.

This is the kind of CLI ergonomic debt that adds up. A user hits one
unhelpful error, googles, finds nothing, and walks away.

## Decision

1. **Every subcommand parses `-h, --help`** through a shared helper. The
   helper renders a uniform usage block: synopsis, options table, examples.
2. **Repo-discovery errors are typed** (`error.NotAgitRepo`) and rendered
   by a single helper that prints:
   - searched path,
   - parent paths checked,
   - the exact command to run (`agit init` from `<dir>`).
3. **Environment errors are typed** (`error.MissingHome`,
   `error.UnwritableConfigDir{path}`) and rendered with file paths and
   suggested fixes.
4. **Examples in help text** mirror the README so README and `--help` do
   not drift (ADR 019 covers the broader drift cleanup).

## Plan

1. Add `src/cli/help.zig` exposing:
   - `pub fn renderUsage(w, usage: UsageSpec) !void`
   - `pub fn renderRepoNotFound(w, searched: []const u8) !void`
   - `pub fn renderEnvError(w, err) !void`
2. Define a `UsageSpec` struct per command and wire it into each
   `cli/*.zig` so `clap` parses `--help` consistently.
3. Add typed errors to `src/store/store.zig:discover` (or wherever repo
   discovery currently lives) and a render path in each consumer.
4. Update `src/cli/init.zig` to validate `$HOME` and config parents up
   front (ties into ADR 006) with the new typed errors.
5. Replace any remaining `try stderr.print("error: {}", .{err})` patterns
   with the helper so output stays uniform.

## Testing

- Snapshot tests for `--help` output of each subcommand. A snapshot file
  per command lives in `tests/golden/help/*.txt`.
- Integration test: run every subcommand outside an agit repo, assert each
  one prints the same "not an agit repository" block with the searched
  path and a usable hint.
- Integration test: run `agit init` with `HOME=/nonexistent` and assert
  the typed env error is rendered.

## Risks and tradeoffs

- Golden help-text snapshots add maintenance: every help-text tweak needs a
  snapshot update. We accept this — it is exactly the drift we are trying
  to catch.
- A central usage renderer is slightly more rigid than free-form help. We
  keep the `UsageSpec` flexible enough for unusual commands (`cat`, `blame`)
  to add a "notes" section.

## Consequences

- `agit <cmd> --help` works for every command, every time.
- Users hitting "not an agit repository" get a one-line fix instead of
  having to read the README.
- README and `--help` drift becomes a test failure rather than a slow
  decay (see ADR 019 for the docs side).
- The bar for adding a new subcommand goes up slightly (must define
  `UsageSpec`), which is the right direction.

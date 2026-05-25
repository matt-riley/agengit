# ADR 031: Structured output and generated completions

**Status:** Implemented
**Date:** 2026-05-25

## Context

`agit` is a CLI for humans, but it is also likely to be called by scripts,
editors, CI checks, and agents. Today the output contract is mostly prose.
That is fine for a young CLI, but it will become friction as commands multiply:

- `doctor` output is readable but not stable for automation,
- `status`, `sessions`, `log`, and `show` have no machine-readable mode,
- ADR 025 proposes `fsck --json`, but no broader output contract exists,
- completions are hand-written static command lists in `src/cli/completion.zig`,
- new commands and options can drift from completions unless humans remember to
  edit several places.

ADR 012 introduces per-command `UsageSpec` metadata and ADR 019 uses it for
README/help sync. That same metadata should also drive completions and provide
a consistent place to declare structured-output support.

## Decision

Define a repository-wide output and completion contract.

1. **Output modes:** commands that are useful to automation gain `--json`.
   Initial targets are `status`, `sessions`, `log`, `show`, `doctor`, and the
   future `timeline`, `grep`, and `fsck` commands.
2. **JSON envelope:** every JSON response includes `schema_version`,
   `command`, and a command-specific `data` object. Diagnostics include
   stable `code`, human `message`, optional `hint`, and optional path/hash
   fields.
3. **Human output remains default:** `--json` is explicit. Human output can
   evolve for readability; JSON output requires compatibility discipline.
4. **UsageSpec owns option metadata:** extend ADR 012's `UsageSpec` with
   option names, argument kinds, repeatability, and completion hints.
5. **Generated completions:** `agit completion <shell>` renders command and
   option completions from `UsageSpec`. Hand-maintained command lists are
   removed.
6. **Dynamic completions are narrow:** session-id and hash-prefix completion
   may be added later through explicit completion helpers, but static command
   and option completion must not require opening a store.

## Plan

1. Extend `src/cli/help.zig` from ADR 012 with option metadata suitable for
   help text, docgen, and shell completion rendering.
2. Add `src/cli/output.zig` with small helpers for JSON envelopes and
   diagnostic objects.
3. Implement `--json` for `status` first because its schema is small and
   useful in tests.
4. Add JSON modes for `sessions`, `log`, `show`, and `doctor`, keeping schema
   names and versioning explicit.
5. Replace the static completion strings in `src/cli/completion.zig` with
   renderers for bash, zsh, fish, and Nushell using registered command specs.
6. Add schema notes under `docs/format/cli-json-v1.md` once at least two
   commands use the envelope.

## Testing

- Unit tests for JSON envelope rendering and diagnostic rendering.
- E2E test: `agit status --json` emits parseable JSON with
  `schema_version`, `command`, and `data`.
- E2E test: `agit doctor --json` reports health items with stable codes and
  does not include terminal glyphs.
- E2E test: generated completions include every registered public command and
  its options.
- Regression test: adding a command without a `UsageSpec` fails a compile-time
  or test-time registry check.
- Golden tests cover generated completion output for each supported shell.

## Risks and tradeoffs

- JSON schemas create compatibility expectations. Keep v1 minimal and version
  the envelope from day one.
- Completion generation couples commands to metadata quality. That is the same
  discipline ADR 012 and ADR 019 already require, so the added constraint is
  acceptable.
- Dynamic completions can become slow or surprising if they open large stores.
  Keep them opt-in and avoid store access in the default completion path.

## Consequences

- Scripts, agents, and editor integrations can consume `agit` output without
  scraping prose.
- Human output can improve without breaking automation.
- Completion drift becomes a test failure instead of a manual checklist item.
- ADR 012's `UsageSpec` becomes the central command metadata contract for help,
  README generation, and shell completion.

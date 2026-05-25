# ADR 029: Guided setup and hook-install preview

**Status:** Implemented
**Date:** 2026-05-25

## Context

`agit init` is the first real trust moment in the product. It detects supported
agent CLIs and edits user-owned configuration files for Claude Code, Codex CLI,
and Gemini CLI. ADR 005 and ADR 006 make those edits conservative and
crash-safe, but the user experience is still mostly "run the command and see
what happened."

That creates several small anxieties:

- users cannot preview which config files will be touched,
- users cannot intentionally install only one agent's hooks,
- the command does not explain why an installed agent was skipped,
- a no-op run is easy to confuse with a broken install,
- the next step after setup is implicit instead of guided.

For a recorder that captures private local history, setup should make the
decision boundary visible before it writes.

## Decision

Add a guided setup planning layer around hook installation.

1. **Init plan:** introduce a shared `InitPlan` model that records each
   supported agent, whether its binary was found, the config path, current
   config state, proposed writes, backup path, and any blocker.
2. **Dry run:** `agit init --dry-run` renders the plan without creating
   directories, writing backups, or mutating config files.
3. **Agent selection:** `agit init --agent <claude|codex|gemini>` limits the
   plan and writes to selected agents. The flag may be repeated. Plain
   `agit init` keeps today's auto-detect-all behavior.
4. **Action summary:** successful writes end with a concise summary:
   configured agents, skipped agents, backup files created, and the next
   command to run (`agit doctor`).
5. **Setup diagnostics:** skipped or blocked agents use the typed error and
   hint renderer from ADR 012 rather than raw filesystem or JSON errors.

This ADR does not add a terminal wizard or prompt for confirmation. `agit`
remains scriptable; the preview is an explicit command mode.

## Plan

1. Extract the repeated agent metadata from `src/cli/init.zig`,
   `src/cli/uninstall.zig`, and `src/cli/doctor.zig` into a small shared table.
2. Add an `InitPlan` builder that can inspect agent binaries and config files
   without mutating anything.
3. Teach `init` to parse `--dry-run` and repeatable `--agent`.
4. Render a human-readable plan and summary through the shared CLI output
   helpers from ADR 012.
5. Reuse the plan in `doctor` later for setup-oriented recommendations, but do
   not block this ADR on a new `doctor --setup` command.

## Testing

- E2E test: `agit init --dry-run` with fake Claude/Codex/Gemini binaries
  reports intended config writes and leaves `$HOME` unchanged.
- E2E test: `agit init --agent codex` writes only Codex hooks and does not
  create Claude or Gemini config directories.
- E2E test: repeating `--agent` installs exactly the selected subset.
- E2E test: an unknown agent name exits non-zero with a stable diagnostic and
  valid agent list.
- E2E test: successful setup summary names backup files and suggests
  `agit doctor`.
- Unit tests cover plan construction for missing binary, missing config,
  valid config, malformed config, and non-object config.

## Risks and tradeoffs

- The plan can drift from the write path if they grow separately. Keep the
  write path driven by the plan rather than re-deriving decisions.
- Dry-run output becomes another user-facing contract. Cover it with golden
  tests so wording changes are deliberate.
- Agent selection adds option parsing complexity, but it reduces the surprise
  of editing multiple user config files at once.

## Consequences

- First-run setup becomes explainable before it is mutating.
- Users can adopt `agit` one agent at a time.
- `doctor` gains a future source of setup advice without duplicating init's
  detection rules.
- ADR 012's typed diagnostics become visible at the highest-friction entry
  point in the CLI.

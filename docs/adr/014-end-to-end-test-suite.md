# ADR 014: End-to-end test suite under `tests/`

**Status:** Proposed
**Date:** 2026-05-25

## Context

`tests/` currently contains only `.gitkeep`. All tests live inline in
source files and are unit-scoped. The highest-risk surfaces in agengit
are *integrative* in nature:

- `agit init` mutating `~/.claude/settings.json`, `~/.codex/hooks.json`,
  `~/.gemini/settings.json`.
- `agit uninstall` doing the inverse.
- Three hook commands consuming JSON from stdin and persisting to
  `.agit/`.
- The recorder under concurrent writers.
- `agit doctor` reporting truthfully on a real store.

None of these are covered today. A regression in any of them is the kind
of bug a unit test rarely catches but a user finds immediately.

## Decision

Create a `tests/` tree organised by scope, runnable as `zig build test-e2e`:

```text
tests/
  e2e/             one process per test, real filesystem
    init/
    uninstall/
    hooks/
    record_replay/
    doctor/
  property/        property-based / fuzz round-trip
  golden/          snapshot tests (help text, doctor output)
  fixtures/        shared payload samples per agent
```

Each e2e test:

- Creates a tempdir for `HOME` and `CWD`.
- Spawns the just-built `agit` binary as a subprocess.
- Asserts on stdout/stderr, exit code, and resulting filesystem state.
- Tears the tempdir down on exit.

## Plan

1. Add `zig build test-e2e` step in `build.zig` that depends on the
   installed binary.
2. Add `tests/support/harness.zig` with helpers for tempdir setup,
   subprocess launch, and filesystem assertions.
3. Author the initial coverage:
   - `init/fresh.zig` — empty HOME, all three agents on PATH → hooks
     installed, no leftover tmp files.
   - `init/existing_user_config.zig` — preserves unrelated keys, writes
     backup, idempotent rerun.
   - `init/malformed_json.zig` — refuses without `--force`, exact byte
     offset reported (ADR 006).
   - `init/force.zig` — overwrites and backs up.
   - `uninstall/clean.zig` — removes only managed hooks, leaves user
     keys.
   - `uninstall/malformed.zig` — warns but leaves file (ADR 006).
   - `hooks/claude_payloads.zig` — replay golden payloads per event.
   - `hooks/codex_payloads.zig`, `hooks/gemini_payloads.zig` — ditto.
   - `record_replay/concurrent_writers.zig` — N parallel hook writers,
     assert all steps land, index matches refs (ADR 007 + ADR 009).
   - `record_replay/crash_recovery.zig` — kill mid-write, reopen,
     assert reconcile repairs (ADR 007).
   - `doctor/healthy_store.zig`, `doctor/drifted_store.zig` — exit codes
     and reported issues.
4. Wire `test-e2e` into the CI matrix from ADR 013.
5. Add `tests/golden/` for snapshot files (`--help` output per command,
   `agit doctor` output on canonical fixtures).

## Testing

The suite *is* the test. To validate the harness itself:

- Run with an intentionally broken binary build and confirm assertions
  fire.
- Run twice in succession; confirm no shared state leaks across runs.
- Run with `--keep-tempdir` to inspect artifacts when a test fails.

## Risks and tradeoffs

- E2E tests are slower than unit tests. We mitigate by running the full
  suite only in CI; `zig build test` continues to run unit tests fast
  for local iteration.
- Spawning the binary means tests depend on build artifacts; a clean
  build is required before running e2e. The `build.zig` step expresses
  this dependency.
- Golden snapshots require update discipline. We add a
  `AGIT_UPDATE_GOLDEN=1` env var to regenerate intentionally.

## Consequences

- The riskiest surfaces — config mutation, hooks, recorder concurrency —
  get real coverage.
- Future ADRs (006, 007, 009, 010, 011, 012) all reference this suite
  for verification, so the investment pays back across the roadmap.
- Contributors get a clear place to add reproducers for bug reports
  before fixing them.
- README and `--help` drift becomes a CI failure (ties to ADR 019).

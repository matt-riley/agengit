# Copilot Instructions for `agengit`

## Build, test, and lint commands

Use Zig `0.16.0`.

```sh
zig build
zig build run -- version
zig build test
zig build test-e2e
zig build check-fmt
zig build fmt
```

Targeted test runs:

```sh
# Run one unit-test file or filter by test name
zig test src/store/snapshot.zig --test-filter "captures text files"

# Run a single e2e case by filtering the e2e aggregator tests
zig test tests/e2e/all.zig --test-filter "doctor healthy store"
```

CI parity build targets:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe
```

## High-level architecture

`agit` is a Zig CLI that records AI-agent session activity into a local `.agit/` store.

- `src/main.zig` is the command router. It dispatches user-facing commands (`init`, `doctor`, `status`, `sessions`, `log`, `show`, `cat`, `reindex`, etc.) and internal hook entrypoints (`claude-hook`, `claude-tool-batch-hook`, `codex-hook`, `gemini-hook`).
- `src/cli/init.zig` installs/updates hook config in user-level agent configs (`~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json`) and preserves non-`agit` hook entries.
- Hook handlers in `src/cli/*hook*.zig` parse JSON payloads from stdin and forward normalized events into the recorder.
- `src/recorder.zig` is the core pipeline:
  1. stage prompt/tool events in `.agit/tmp/<staging-key>.json`,
  2. on assistant/finalize, snapshot the workspace,
  3. write immutable content-addressed objects,
  4. CAS-update session refs and index rows.
- `src/store/` contains persistence primitives:
  - `object.zig`: content-addressed object storage (`.agit/objects/`),
  - `ref.zig`: session head refs under `.agit/refs/sessions/`,
  - `index.zig`: SQLite query index (`.agit/index.db`),
  - `snapshot.zig` + `ignore.zig`: workspace capture and filtering.
- `src/cli/reindex.zig` rebuilds SQLite state from object/ref truth, so index drift is recoverable.
- E2E tests live in `tests/e2e/` with a shared subprocess harness in `tests/e2e/support/`.

## Key conventions in this repository

- Treat the content-addressed object store and session refs as canonical; treat SQLite as a rebuildable query helper (`agit reindex`).
- Hook commands must be agent-safe: they log failures and return cleanly instead of breaking Claude/Codex/Gemini workflows.
- Use crash-safe file updates for store/config writes (`createFileAtomic` + sync/replace patterns) and lock contention-sensitive paths with `util/file_lock.zig`.
- Keep `init`/`uninstall` behavior idempotent and non-destructive to user-owned config keys; only manage `agit` entries and `_agit` metadata.
- Use Conventional Commits for every commit subject (`type(scope): summary` or `type: summary`); CI enforces this in `.github/workflows/ci.yml` via the `commit-messages` job.
- Keep CLI/help/docs synchronized when behavior changes: update command usage text in `src/main.zig`, README examples, and relevant tests/golden snapshots together.
- Snapshot filtering is intentionally conservative. `.agitignore` only supports simple patterns (exact, leading `*` suffix-match, trailing `*` prefix-match); avoid adding assumptions based on full gitignore semantics.
- For architecture-impacting changes (store format, hook behavior, durability, release process), update or add an ADR under `docs/adr/`.

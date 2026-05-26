# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`agit` is a Zig CLI that records AI-agent coding activity into a local `.agit/` store so you can inspect what happened between commits. It hooks into Claude Code, OpenAI Codex CLI, and Google Gemini CLI to capture prompts, tool calls, and workspace snapshots as content-addressed objects.

## Build commands

Requires Zig `0.16.0`.

```sh
zig build                              # build ./zig-out/bin/agit
zig build run -- version              # run via build graph
zig build check                       # format + docs + config + unit checks
zig build test                        # unit tests (embedded test blocks)
zig build test-e2e                    # end-to-end tests
zig build test-property               # property-based recorder/reindex tests
zig build fuzz-hooks -- --time=60s    # bounded fuzz harnesses
zig build bench-durable               # durable-write microbenchmark
zig build bench-resolve-prefix        # object-prefix resolution benchmark
zig build fmt                         # format src/, tests/, bench/, tools/, build.zig, build.zig.zon
zig build check-fmt                   # verify formatting for the same paths
./scripts/smoke-doctor.sh             # full smoke test (requires built binary)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe  # cross-compile
```

Use `zig build check` as the default local verification command. Run
`zig build test-e2e` as well when you change observable CLI behavior, recorder
flows, or fixtures.

To regenerate e2e golden files intentionally:

```sh
AGIT_UPDATE_GOLDEN=1 zig build test-e2e
```

## Architecture

Recording flows through layered phases:

1. **Hook adapters** (`src/cli/claude_hook.zig`, `claude_tool_batch_hook.zig`, `codex_hook.zig`, `gemini_hook.zig`) — parse agent-specific JSON payloads from stdin and call into the Recorder.
2. **Recorder** (`src/recorder.zig`) — orchestrates staging, snapshotting, and committing. Each agent turn flows through three hook calls: `recordUserPrompt` → `recordToolUse` (zero or more) → `recordAssistantAndFinalize`. Between calls, partial state is accumulated in a JSON staging file under `.agit/tmp/<key>.json`.
3. **Snapshotter** (`src/store/snapshot.zig`) — walks the working tree, applies `.agitignore` rules, and writes a `Tree` object.
4. **Object store** (`src/store/`) — content-addressed (BLAKE3) storage. Object types: `blob`, `tree`, `step`, `blame`. Objects live under `.agit/objects/<2-hex-char shard>/<remaining-62 hex>`.
5. **Hash layer** (`src/store/hash.zig`) — 32-byte BLAKE3 digest wrapped in `Hash` with hex round-trip helpers.

Supporting modules:
- `src/hook.zig` — payload size limits, parse error diagnostics, failure context structs used by all hook adapters.
- `src/store/ref.zig` — session HEAD ref files under `.agit/refs/sessions/<origin-hex>/<session-hex>`.
- `src/store/index.zig` — SQLite (via zqlite) query accelerator. Rebuildable with `agit reindex`. Tracks objects, steps, messages, tool_calls, sessions.
- `src/store/store.zig` — `Store` struct that owns the root dir and index; provides `writeBlob/Tree/Step`, `casRef` (compare-and-swap ref advance), `commitFinalizedStep`, `reconcile`.
- `src/util/` — cross-cutting OS helpers: `file_lock.zig` (lock files with timeout), `fs.zig` (atomic writes, directory fsync), `atomic_json.zig`, `home.zig`, `exe_path.zig`.
- `src/cli/` — one file per command; commands receive `io`, `gpa`, and an args iterator and write to stdout/stderr.
- `src/cli/output.zig` — `cli-json-v1` envelope used by all `--json` outputs.

## Key design properties

**Hooks are fail-open.** If capture fails, the hook logs to `.agit/log/hook-error.log` and exits 0 so the agent continues. Diagnose issues with `agit doctor --last-hook-error`.

**CAS-first finalize.** `commitFinalizedStep` uses compare-and-swap on the session HEAD ref (under a file lock) and retries up to `max_finalize_retries` times if a concurrent writer races ahead.

**Staging files are locked individually.** `appendMessage`/`appendToolCall`/`consumeStaging` each acquire `tmp/<key>.json.lock`. The staging file is deleted while the lock is held during finalization.

**Durable writes by default.** `AGIT_FSYNC=0` disables directory fsync — only use in tests or microbenchmarks.

**Index is a query accelerator, not the source of truth.** The canonical record is in `objects/` and `refs/`. `agit reindex` can rebuild `index.db` from scratch.

**Object prefix resolution** falls back to filesystem scan if `index.db` doesn't have `objects_complete = true` (set after first `agit reindex` or after the store bootstraps empty).

## Testing layout

- Unit tests live in `test "..."` blocks directly in each `.zig` file. `src/main.zig` pulls them all into the test binary with `_ = @import(...)`.
- E2E tests live in `tests/e2e/` and use `tests/e2e/support/harness.zig` to spawn the built binary. Golden output lives in `tests/golden/`; update with `AGIT_UPDATE_GOLDEN=1`.
- Property tests are in `tests/property/` and use `src/test_support.zig` (which imports zqlite).
- Fuzz harnesses are in `tests/fuzz/hooks.zig` and use the `hook` module directly.
- `src/fixtures/hooks/` and `tests/e2e/fixtures/hooks/` contain representative agent hook payloads; add fixtures there rather than hard-coding large JSON inline.

When writing tests targeting `.agit/tmp/`, target only top-level `.agit/tmp/*.json` files — recursive walks also see turn-state files under `.agit/tmp/turns/` and will accidentally exercise recovery-turn behavior instead of corrupt-staging handling.

## Environment variables

| Variable | Default | Effect |
|---|---|---|
| `AGIT_FSYNC=0` | fsync on | Disables directory fsync |
| `AGIT_LOCK_TIMEOUT_MS=<ms>` | 10000 | Lock acquisition timeout |
| `AGIT_HOOK_MAX_BYTES=<bytes>` | 16 MiB | Hook payload size cap |
| `AGIT_UPDATE_GOLDEN=1` | off | Overwrites golden files during e2e run |

## Coding conventions

- Follow `zig fmt`; don't hand-align against it. Run `zig build check` before submitting, and `zig build test-e2e` when behavior changes need end-to-end coverage.
- New subcommands go in `src/cli/<command>.zig`; store primitives in `src/store/`; OS helpers in `src/util/`.
- Names: `snake_case` for locals/functions, `PascalCase` for types, lowercase filenames.
- When changing CLI output, keep `src/main.zig` usage text, README examples, and golden files in sync.
- Structured CLI output uses the `cli-json-v1` envelope (`src/cli/output.zig`); all `--json` flags must use it.

## ADRs

Key design rationale is documented in `docs/adr/`. Add or update an ADR when changing store format, hook behavior, durability guarantees, or release process. Existing ADRs cover: store directory, JSON config, hook process model, snapshot policy, hook install contract, crash-safe config writes, atomic ref/index updates, durable writes, file locking, CAS-first finalize, payload diagnostics, CLI help, CI hardening, e2e tests, object prefix resolution, snapshot diff/blame perf, and hook deduplication.

## Commit style

Use Conventional Commit prefixes: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`. Keep subjects imperative and scoped, e.g. `fix: preserve user hooks during uninstall`. Releases are generated by Release Please.

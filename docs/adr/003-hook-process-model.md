# ADR 003: Hook Process Model

**Status:** Accepted

## Context

Agent hooks (Claude Code, Codex CLI, Gemini CLI) invoke external commands synchronously before/after each agent action. If a hook command is slow, crashes, or exits non-zero, it can degrade or block the agent process.

## Decision

### Per-invocation process model

Each hook event spawns a fresh `agit <hook-subcommand>` process. There is no long-lived hook daemon in v1.

### Non-negotiable exit invariant

Hook commands **always exit 0**. Every error path logs a structured JSON entry to `.agit/log/hook-error.log` and exits 0. The agent process must never be blocked or terminated by a hook failure.

### Lock ordering (to prevent deadlocks)

When a hook command finalizes a step:

1. Write immutable objects (blobs, trees, steps) — no lock needed; object writes are idempotent by content hash.
2. Open SQLite transaction in WAL mode with `busy_timeout = 5000ms`.
3. Acquire ref lock (`O_CREAT|O_EXCL` on `.agit/refs/sessions/<id>.lock`) — only for the CAS compare-and-swap.
4. Update the ref file.
5. Commit the SQLite transaction.
6. Release the ref lock.

### Latency contract

Hook commands must be fast enough not to degrade agent UX. Latency is tracked in integration tests. Heavy work (e.g., full workspace snapshots in very large repos) is subject to the snapshot policy size/ignore caps.

### Concurrency

Multiple hooks for the same session can be invoked concurrently (e.g., parallel tool calls). WAL mode and `busy_timeout` handle SQLite concurrency. The ref lock ensures only one process swaps the session ref at a time.

## Consequences

- Per-process model is simpler to implement and test than a daemon; revisit if latency becomes a concern.
- The exit-0 invariant protects agent processes from `agit` bugs during development.
- Lock ordering and WAL mode must be implemented before any concurrent use (Phase 2).

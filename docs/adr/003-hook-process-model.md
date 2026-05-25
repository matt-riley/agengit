# ADR 003: Keep hook commands short-lived and agent-safe

**Status:** Accepted
**Editorial note:** Reworded on 2026-05-25 for clarity; the decision is unchanged.

## Context

Claude Code, Codex CLI, and Gemini CLI can call external hook commands during an agent session. Those hooks are the doorway into `agit`, but they run in the agent's path. If a hook hangs, crashes, or exits non-zero, the user's agent workflow can suffer.

The recorder should be useful, not a gremlin sitting on the brakes.

## Decision

Each hook event starts a fresh `agit` process:

- `agit claude-hook user`
- `agit claude-tool-batch-hook`
- `agit claude-hook assistant`
- `agit codex-hook`
- `agit gemini-hook`

Hook commands must catch errors, report them through the hook logging path, and return successfully to the agent.

When a hook finalizes a step, writes should follow this order:

1. Write immutable objects.
2. Update the SQLite index inside a transaction.
3. Acquire the session-ref lock for the shortest possible compare-and-swap window.
4. Update the ref.
5. Commit index work.
6. Release the ref lock.

## Consequences

- Hooks stay simple and testable.
- A broken capture should not break the user's agent session.
- `.agit/log/hook-error.log` is the first place to check when capture looks quiet.
- A future daemon can be considered only if process startup or snapshot latency becomes a real user problem.

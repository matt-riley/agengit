# ADR 033: Git commit and session correlation

**Status:** Implemented
**Date:** 2026-05-31

## Context

The product framing in the README is "Git tracks commit history, while `agit`
tracks agent execution history," and the headline promise is to "inspect what
happened between commits." Today nothing actually links the two histories:

- steps record agent origin, session ids, messages, tool calls, and workspace
  snapshots,
- but no step records the surrounding Git state (commit SHA, branch, dirty
  flag),
- and no command answers "which agent steps produced the change in this
  commit?" or "what did agents do between `v1.2.0` and `HEAD`?"

Investigation views (ADR 030) and historical grep (ADR 022) help a user move
around agit's own history, but the bridge back to Git — the history users
already reason about — is missing. Without it, the core "between commits" claim
is aspirational.

## Decision

Capture lightweight Git context at finalize time and add a correlation view
that maps a commit range to the agent steps recorded within it.

1. **Captured Git context:** at `recordAssistantAndFinalize`, best-effort read
   the workspace's current commit SHA, branch name, and a boolean
   working-tree-dirty flag, and store them on the step object as optional
   fields. Capture must be fail-open: a missing or non-Git workspace records
   nulls and never breaks the hook.
2. **No libgit dependency:** read Git state by shelling out to `git` when
   present, or by reading `.git/HEAD` and `.git/refs` directly, to avoid a new
   native dependency. The chosen mechanism is documented in the plan.
3. **Correlation command:** add `agit between <rangeA> [rangeB]` (default
   `rangeB = HEAD`) that resolves the two commits, then lists steps whose
   captured commit SHA falls in the range, ordered chronologically, grouped by
   session.
4. **Status and timeline enrichment:** surface the captured branch/commit on
   `agit timeline` and `agit status` when present, so the agent history reads
   against familiar Git anchors.
5. **Backfill tolerance:** steps recorded before this ADR have null Git
   context. `agit between` must degrade gracefully, reporting how many steps
   lacked commit data rather than failing.

This ADR adds metadata and a read view only. It does not make agit depend on
Git for correctness, and it never writes to the Git repository.

## Plan

1. Add optional `git_commit`, `git_branch`, and `git_dirty` fields to the step
   object schema and document the additive, backward-compatible fields.
2. Add a `src/util/git.zig` helper that returns best-effort Git context for a
   workspace root with a hard timeout and fail-open semantics.
3. Wire the helper into the recorder finalize path behind the existing
   fail-open error handling.
4. Index the commit SHA in SQLite so range membership queries avoid full object
   scans; keep objects/refs canonical and rebuildable via `agit reindex`.
5. Implement `cli/between.zig` resolving commits via the same Git helper.
6. Enrich `agit timeline` and `agit status` output and golden files.
7. Update README examples and command docs after the command is implemented.

## Testing

- Unit test: Git helper returns commit/branch/dirty for a synthetic repo and
  nulls for a non-Git directory without erroring.
- E2E test: record steps across two commits, then `agit between <A> <B>` lists
  only the steps captured in that range, grouped by session.
- E2E test: `agit between` on a store with pre-ADR steps reports the count of
  steps lacking Git context instead of failing.
- E2E test: hook still exits 0 when `git` is absent from PATH.
- Golden tests cover timeline/status output with and without Git context.

## Risks and tradeoffs

- Shelling out to `git` per finalize adds latency. A short timeout and caching
  per turn keep it bounded; the dirty check must not stat the whole tree twice.
- Commit SHA alone is ambiguous across rebases and amends. The view reports best
  effort and never claims authoritative causality.
- Squash/rebase workflows can move recorded changes off the commit they were
  captured against. Document this as a known limitation rather than guessing.

## Consequences

- The "what happened between these commits?" promise becomes a real command.
- Agent history gains stable Git anchors without a native Git dependency.
- Future tooling (PR review summaries, CI annotations) can build on the same
  commit-to-step mapping.

# ADR 037: Cross-step diff and session analytics

**Status:** Implemented
**Date:** 2026-05-31

## Context

`agit diff` (ADR 030) renders a text diff between a step tree and its *parent*
tree only. That answers "what did this one step change?" but not the equally
common questions:

- what changed across a whole session, or between two arbitrary steps?
- what changed between the start and end of an agent's work?

Separately, the index already tracks rich operational data — sessions, steps,
messages, and `tool_calls` — but nothing surfaces it as insight. Users cannot
see which tools an agent leaned on, which files it touched most, or how much
work a session represented. The data exists; the reporting does not.

## Decision

Generalize diff to arbitrary endpoints and add an analytics command that
summarizes recorded activity from existing indexed data.

1. **Cross-step diff:** extend diff to `agit diff <hashA> <hashB> [-- <path>]`,
   rendering changes between any two step trees rather than only step-vs-parent.
   The existing single-argument form keeps its parent-relative behavior for
   compatibility.
2. **Session diff shorthand:** add `agit diff --session <id>` to diff the first
   step's *parent* tree against the latest step. This captures the true
   start-of-work baseline; sessions whose first step has no parent use an empty
   tree baseline.
3. **Analytics command:** add `agit stats` that reports, from indexed rows:
   tool-call frequency by tool name, most-changed file paths, steps and turns
   per session, and capture time span. Default is a repository-wide summary;
   `--session` scopes to one session.
4. **Reuse, don't recompute:** stats reads SQLite aggregates for sessions,
   steps, turns, and tool-call counts. Counts that need tree walks (changed-file
   frequency) reuse the ADR 030 tree comparison path and are bounded to the
   first 500 matching steps.
5. **Structured output:** both features support `--json` via the `cli-json-v1`
   envelope so dashboards and CI can consume them.
6. **Privacy and size limits:** cross-step diff honors the same display
   redaction (ADR 026) and size caps (ADR 016) as the existing diff path.

## Plan

1. Refactor the diff renderer to accept two arbitrary tree hashes; adapt the
   current parent-relative path to call it.
2. Add CLI parsing for the two-hash form and `--session` shorthand in
   `cli/diff.zig`, resolving session endpoints from refs/index.
3. Add index aggregate queries for tool-call counts, per-session step/turn
   counts, and capture spans.
4. Implement `cli/stats.zig` using those aggregates, plus bounded tree-stat
   reuse for most-changed paths.
5. Add `--json` envelopes and golden tests for both.
6. Update README examples and command docs after implementation.

## Testing

- E2E test: `agit diff <A> <B>` renders changes between two non-adjacent steps
  and matches a hand-computed expectation.
- E2E test: single-argument `agit diff <step>` still diffs against its parent
  (no behavior change).
- E2E test: `agit diff --session <id>` diffs the first step's parent tree vs
  the latest captured tree.
- E2E test: `agit stats` reports correct tool-call counts and per-session
  step/turn totals for a known recorded fixture.
- Unit test: index aggregate queries return expected counts for synthetic rows.
- Golden tests cover human and `--json` output for diff and stats.

## Risks and tradeoffs

- Arbitrary-endpoint diffs can be large. Existing size caps and path filters
  bound output; default to a summary when content is oversized.
- Stats derived from a rebuildable index are only as complete as the last
  `reindex`. Document that stats reflect indexed state and point to `reindex`
  on drift.
- Most-changed-path analysis needs tree comparison and can be costly on long
  histories. The implemented command includes it by default but caps the walk at
  500 matching steps and reports when the tally is capped.

## Consequences

- Diff answers "what changed across this work," not just "this one step."
- Already-captured tool and message data becomes actionable insight.
- CI and dashboards gain a structured analytics surface over agent activity.

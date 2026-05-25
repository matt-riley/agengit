# ADR 030: Investigation workflow views

**Status:** Proposed
**Date:** 2026-05-25

## Context

The product promise in the README is "What happened here?" The current read
commands are useful, but they still expose the store from the inside out:

- `agit sessions` lists session ids and head hashes,
- `agit log` lists step hashes and turn ids,
- `agit show` prints metadata, message previews, tool names, and a tree hash,
- `agit cat` prints raw objects.

Those commands are good primitives. They are not yet the fastest path for a
human trying to answer:

- Which agent changed this repository yesterday?
- What did the agent do in this session?
- Which files were captured in this step?
- What changed between this step and its parent?
- Is the store healthy enough to trust before I investigate?

ADR 022 adds historical full-text search, which helps users find a remembered
phrase. This ADR covers the adjacent inspection workflow once the user has a
session or step in hand.

## Decision

Add investigation-focused views that summarize history in terms of sessions,
turns, tools, and file changes rather than only hashes.

1. **Timeline view:** add `agit timeline` as the human-first chronology view.
   It shows recent steps across sessions by default, with filters for
   `--origin`, `--session`, `--since`, `--until`, and `--limit`.
2. **Step file views:** extend `agit show <step>` with `--files` and `--stat`.
   `--files` lists captured paths and sizes from the step tree. `--stat`
   compares the step tree to its parent tree and summarizes added, modified,
   deleted, and unchanged paths.
3. **Step diff:** add `agit diff <step> [-- <path>]` after `--stat` exists.
   It renders text diffs between the parent tree and the step tree, with size
   caps from ADR 016 and display redaction from ADR 026.
4. **Status dashboard:** enrich `agit status` from counts-only output into a
   compact dashboard: store path, latest capture time, sessions, steps,
   pending staging warnings, configured agents, privacy mode when ADR 026
   exists, and the most relevant next command.
5. **No raw-content surprise:** commands that print captured prompts, tool
   results, file content, or diffs must respect the display-time redaction
   controls from ADR 026. Before ADR 026 lands, new views should prefer
   metadata, paths, counts, and short previews over full content.

This ADR does not replace `agit grep`; timeline and diff answer "what happened
around this point?" while grep answers "where did this text appear?"

## Plan

1. Add tree-reading helpers that return path, blob hash, mode, and size from a
   step tree.
2. Add a tree comparison helper for added/modified/deleted path summaries.
3. Implement `agit show --files` first because it only needs one tree.
4. Implement `agit show --stat` next because it needs parent-tree comparison
   but not full blob reads.
5. Implement `agit timeline` using indexed session and step rows, adding index
   queries as needed for limit and date filters.
6. Enrich `agit status` after the helpers exist, reusing doctor checks where
   they are cheap and avoiding full `fsck` traversal by default.
7. Add `agit diff` only after stat output and redaction behavior are stable.

## Testing

- E2E test: record multiple sessions, run `agit timeline --limit 2`, and assert
  newest steps appear with origin, session, turn, preview, and short hash.
- E2E test: `agit show <step> --files` lists captured file paths and sizes.
- Unit test: tree comparison reports added, modified, deleted, and unchanged
  paths from two synthetic trees.
- E2E test: `agit show <step> --stat` compares a step against its parent and
  renders stable counts.
- E2E test: `agit diff <step> -- path` renders a bounded text diff and skips
  binary or oversized content with a clear summary line.
- Golden tests cover human output for timeline, file list, stat, and enriched
  status.

## Risks and tradeoffs

- Diff output can expose sensitive content. Full diff rendering must wait for
  ADR 026 display controls or default to redacted/metadata-only output.
- Timeline can become noisy in long-running repositories. Default limits and
  filters are required from the first release.
- Status can become slow if it does too much. It should use cheap checks and
  point to `agit doctor`, `agit fsck`, or `agit gc` for deeper work.

## Consequences

- Users get a direct investigation loop: status, timeline, show, stat, diff.
- The CLI becomes less hash-first without hiding hashes from power users.
- ADR 022 search results gain a natural follow-up path into timeline and diff.
- Future TUI or editor integrations can reuse the same underlying read helpers.

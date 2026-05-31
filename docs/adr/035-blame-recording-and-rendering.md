# ADR 035: Blame recording and rendering

**Status:** Implemented
**Date:** 2026-05-31

## Context

`agit blame` is already an advertised command with a stub implementation. The
README notes that "Blame recording is not yet available," and `cli/blame.zig`
prints a placeholder explaining that blame maps will be written "in a future
phase when the recorder calls `store.writeBlame()`." The object store even
reserves a `blame` object type (see CLAUDE.md object types: `blob`, `tree`,
`step`, `blame`).

This is a promised-but-unfinished feature rather than a new surface. Closing it
gives users per-line attribution: "which agent step last changed this line of
this file?" — the natural agent-history analogue to `git blame`, and a strong
complement to the commit correlation in ADR 033.

## Decision

Finish blame end to end: record incremental per-file line attribution at
finalize, store it as a `blame` object, and render it through the existing
`agit blame` command.

1. **Blame object:** define the `blame` object as a per-file map from line
   ranges to the step hash (and session/turn) that last changed them. It is
   content-addressed like other objects and rebuildable.
2. **Incremental recording:** at finalize, for each text file that changed
   versus the parent tree, compute a line-level diff (reusing ADR 016 diff
   machinery) and update that file's blame map: changed lines point to the new
   step; unchanged lines keep their prior attribution.
3. **Bounded cost:** blame recording respects the large-file cap
   (`AGIT_MAX_FILE_BYTES`) and skips binary/oversized files. It must stay
   fail-open and must not dominate finalize latency.
4. **Rendering:** replace the placeholder in `cli/blame.zig` with real output:
   for the requested file at the latest (or `--step`-selected) snapshot, print
   each line prefixed by short step hash, origin, and timestamp. `--no-limits`
   disables the default large-file cap for one run, as the help already hints.
5. **Rebuildable:** `agit reindex` reconstructs blame maps from the step chain
   so blame survives index loss and can be backfilled for pre-blame history.

## Plan

1. Specify the `blame` object format in `docs/format/` before implementation.
2. Add `store.writeBlame()` and a blame reader under `src/store/`.
3. Add a line-diff helper (or reuse ADR 016's) that yields changed line ranges
   between parent and child blob versions.
4. Wire incremental blame updates into `recordAssistantAndFinalize` behind the
   fail-open guard and the file-size cap.
5. Implement blame reconstruction in `cli/reindex.zig` from the step chain.
6. Replace the `cli/blame.zig` placeholder with real rendering and `--json`.
7. Update README to drop the "not yet available" note and add an example.

## Testing

- Unit test: blame map update attributes only changed line ranges to the new
  step and preserves prior attribution for untouched lines.
- E2E test: two sessions edit different lines of a file; `agit blame <file>`
  attributes each line to the correct step.
- E2E test: `agit reindex` rebuilds identical blame output after deleting
  `index.db`.
- E2E test: oversized/binary files are skipped without error and reported.
- Golden tests cover human and `--json` blame output.

## Risks and tradeoffs

- Line-level diffing on every finalize adds CPU cost. Caps, skips, and reuse of
  existing diff code keep it bounded; blame can be made opt-in if needed.
- Renames currently break attribution continuity. v1 treats a rename as
  delete+add and documents the limitation; rename detection can follow.
- Blame storage grows with churn. Repacking (ADR 021) and gc (ADR 020) should
  cover blame objects so long-running repos stay manageable.

## Consequences

- A previously stubbed, advertised command becomes fully functional.
- Users gain per-line agent attribution that pairs naturally with ADR 033.
- The reserved `blame` object type gains a concrete, documented format.

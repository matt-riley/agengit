# ADR 020: Garbage collection and store maintenance

**Status:** Implemented
**Date:** 2026-05-25

## Context

`agit` is designed to be a "black box" recorder that stays out of the user's
way. However, every agent turn captures a workspace snapshot and writes new
immutable objects to `.agit/objects/`. While snapshots share identical blobs,
even small changes to files create new blobs, and the object store grows
monotonically.

Currently, there is no mechanism to:
1. Delete unreachable objects (objects not referenced by any session HEAD).
2. Clean up abandoned staging files in `.agit/tmp/`.
3. Rotate or prune the `.agit/log/hook-error.log`.

Without maintenance, a long-running repository will eventually consume
significant disk space, most of which may be "garbage" from deleted or
forgotten sessions.

## Decision

Introduce an `agit gc` command that performs automated store maintenance:

1. **Reachability Analysis:** Walk all session refs in `.agit/refs/sessions/`.
   For each ref, traverse the step history (`parent` pointers) and the
   associated trees and blobs. Mark all reachable objects.
2. **Object Pruning:** Delete any file in `.agit/objects/` that is not marked
   as reachable. To prevent race conditions with concurrent hooks, only delete
   objects older than a "grace period" (e.g., 2 hours).
3. **Staging Cleanup:** Delete any `.json` or `.lock` files in `.agit/tmp/`
   that are older than the grace period. These represent turns that were
   interrupted or failed to finalize.
4. **Log Rotation:** If `log/hook-error.log` exceeds a size threshold
   (e.g., 10 MiB), rotate it (keep `log/hook-error.log.1`) or prune old entries.
5. **Index Optimization:** Run `VACUUM` and `ANALYZE` on the SQLite `index.db`
   after pruning objects and sessions.

## Plan

1. Implement reachability traversal in `src/store/gc.zig`. This requires
   loading and parsing step and tree objects recursively.
2. Add `cli/gc.zig` to implement the `gc` command.
3. Add a `--prune-before <YYYY-MM-DD>` flag to `agit gc` to delete session refs
   older than UTC midnight on a given date before running the object prune.
4. Update `agit doctor` to report the amount of "reachable" vs "total"
   object storage to hint when `gc` is needed.
5. Add safety checks to ensure `gc` does not run if a session is actively
   recording by refusing to proceed when live lock files are present and by
   taking a dedicated `gc.lock` during the maintenance pass.

## Testing

- Integration test: create a session, record a step, then delete the ref and
  assert that `gc` removes the objects.
- Integration test: ensure `gc` preserves objects referenced by multiple
  overlapping sessions.
- Integration test: ensure `gc` cleans up stale `.agit/tmp/` files.
- Safety test: ensure `gc` respects the 2-hour grace period for new objects.

## Risks and tradeoffs

- **Data loss:** If the reachability walk is buggy, it could delete active
  history. The grace period and the "ref-first" walk are the primary
  defenses.
- **Performance:** Walking a store with millions of objects can be slow.
  The use of the `objects` table (ADR 015) will help speed up the "find all
  objects" phase.
- **Concurrency:** A hook writing a new object while `gc` is running
  requires careful coordination. The grace period is a standard solution
  used by `git gc`.

## Consequences

- The storage footprint of `.agit/` remains manageable.
- Abandoned staging data is automatically cleared.
- `agit` remains suitable for very long-lived repositories.

# ADR 007: Atomic ref and index updates with startup reconciliation

**Status:** Proposed
**Date:** 2026-05-25

## Context

`src/store/store.zig` finalises a step by:

1. Writing the step object to `.agit/objects/`.
2. Calling `ref.writeRefToPath` to advance the session ref under
   `.agit/refs/sessions/`.
3. Calling `upsertSession` / `insertStep` against the SQLite index at
   `.agit/index.db`.

These three operations are not transactional with each other. If the ref write
succeeds but the SQLite update fails (disk full, schema mismatch, killed
process), the ref points at an object that the index never learns about.

ADR 003 already commits us to a specific order (objects → index → ref CAS),
but the implementation in `src/store/store.zig:260–283` does the ref write
*before* the index write completes. The result is a class of "index says no
such step, but `agit log` via ref says yes" bugs that only surface on the next
read.

`agit reindex` exists and rebuilds the index from objects, but:

- It is manual.
- It does not detect that reindex is *needed*.
- It rebuilds the whole index, which gets expensive as the store grows.

## Decision

1. **Reorder finalize** to match ADR 003 exactly:
   write objects → open SQLite transaction → insert index rows → write ref →
   commit SQLite. Ref CAS is the last durable step inside the lock.
2. **Record a tip marker** in the SQLite `meta` table alongside every commit:
   `last_ref_hash`, `last_step_hash`, `last_step_seq`. The marker is updated in
   the same transaction as the step row.
3. **On startup**, compare the on-disk ref against `meta.last_ref_hash`:
   - If they match, do nothing.
   - If the ref is ahead (object exists, index missing), run an *incremental*
     reindex that walks the chain from `meta.last_ref_hash` to the current
     ref tip.
   - If the ref is behind (index has rows not in ref), log a warning and
     prefer the ref. The orphan index rows are dropped on the next reindex.
4. **`agit doctor`** reports any mismatch and exits non-zero so CI/wrappers
   can catch it.

## Plan

1. Add a `meta` table to `src/store/index.zig` with schema migration:
   `CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)`.
2. Change `src/store/store.zig` finalize to take a `*Index.Transaction`,
   write index rows first, write ref second, then commit. Move the lock
   acquisition to wrap the whole sequence.
3. Add `Store.reconcile(gpa) !ReconcileReport` that runs on every `Store.open`
   and at the top of every CLI command that reads the store.
4. Add incremental reindex in `src/cli/reindex.zig` that accepts
   `--from <hash>` and walks forward. Default behaviour stays "full rebuild"
   for safety.
5. Extend `src/cli/doctor.zig` to call `reconcile` in dry-run mode and report
   drift.

## Testing

- Unit test: open store, write step, kill SQLite mid-transaction (inject via
  test hook), reopen store, assert reconcile detects and repairs.
- Unit test: manually corrupt `meta.last_ref_hash` to a stale value and
  assert incremental reindex catches up correctly.
- Unit test: ref ahead of index → reconcile repairs; index ahead of ref →
  reconcile warns and drops orphans.
- Integration test: run two hook recorders concurrently against the same
  store and assert ref/index stay consistent (see ADR 014).

## Risks and tradeoffs

- Reconcile on every `Store.open` adds a small startup cost. We mitigate by
  short-circuiting when `meta.last_ref_hash` matches the ref tip — typically
  one read.
- Schema migration needs a version bump. Worth a one-time `PRAGMA user_version`
  check.
- Wrapping ref CAS inside a SQLite transaction means SQLite holds a write
  lock across the ref filesystem write. For a single-writer-per-session
  recorder this is fine; multi-writer cases are already serialised by the
  session lock (ADR 009).

## Consequences

- The "ref says yes, index says no" failure mode disappears.
- `agit reindex` becomes a manual override rather than a regular operation.
- `agit doctor` becomes the canonical health check; CI and `pre-commit`
  hooks can rely on it.
- Future store-format migrations have a `meta` table to hang version
  numbers off, which avoids an ADR-001-style on-disk break later.

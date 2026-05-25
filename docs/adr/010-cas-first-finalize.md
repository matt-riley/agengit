# ADR 010: CAS-first finalize to avoid retry churn

**Status:** Proposed
**Date:** 2026-05-25

## Context

`src/recorder.zig:331–374` finalises a step with a retry loop that handles
ref compare-and-swap conflicts. The current shape is:

```text
for retry in 0..3:
  write_step_object()    # always runs, always allocates a new object file
  acquire_lock()
  if cas_ref(parent, new) succeeds: break
  release_lock()
```

The problem: every retry re-serialises the step, hashes it, and writes it to
`.agit/objects/`. Concurrent hook writers under load (e.g. a Claude
`PostToolBatch` flurry) produce duplicate objects that all hash to the same
value, which the object store then has to dedupe. Wasted CPU, wasted I/O,
wasted entropy on retry.

The object write is content-addressed and idempotent — its result depends
only on the step content. There is no reason to redo it inside the retry
loop.

## Decision

Split finalize into two phases:

1. **Prepare** (outside the lock, runs once):
   - Build the step value.
   - Serialise and hash it.
   - Write the object via `linkDurable` (idempotent — same hash always
     wins the same path).
2. **Commit** (inside the lock, retries up to N):
   - Read current ref tip.
   - Validate `parent_hash == expected_parent` (the actual CAS).
   - Begin SQLite transaction.
   - Insert index rows.
   - Write ref atomically (ADR 008).
   - Commit SQLite.
   - Release lock.

If commit fails because the parent moved (another writer landed first), we
re-read the new parent, rebuild only the *header* of the step (linking the
new parent hash), rewrite *just* the linking object, and retry. The body
object is unchanged and not rewritten.

## Plan

1. Refactor `recorder.zig` finalize into `prepareStep` and `commitStep`.
2. Move all object writes out of the retry loop. Only the link/header is
   rewritten on retry.
3. Lower the default retry count from 3 to a configurable N (default 5,
   since each retry is now cheap).
4. Add metrics: `finalize_retries_total`, `finalize_objects_written_total`.
   Exposed via `agit doctor --stats` for now; a future ADR can move this
   into Prometheus-style endpoints if anyone asks.

## Testing

- Unit test: drive `commitStep` with a stubbed ref store that fails CAS
  twice and succeeds on the third try; assert exactly one body object
  was written.
- Stress test (ADR 014): N parallel writers, assert total objects written
  equals total unique steps (no dedupe needed at the FS level).
- Microbenchmark in `bench/`: 1000 sequential finalises, baseline vs new,
  expect ≥30% reduction in object-store writes under contention.

## Risks and tradeoffs

- More code, slightly more state passed between phases.
- The split changes failure semantics: a crash between prepare and commit
  leaves an orphan object in the store. This is harmless — content-addressed
  stores are tolerant of unreferenced objects, and a future `agit gc`
  command (out of scope here) can sweep them.
- The retry counter is now more sensitive to fast loops; we cap retries
  to avoid runaway, but the practical concurrency on a single workstation
  is bounded by the number of agents anyway.

## Consequences

- Concurrent hook writers stop thrashing the object store.
- Object-store I/O scales with the number of unique steps, not the number
  of CAS retries.
- The recorder is easier to reason about: one phase pure and idempotent,
  one phase transactional. Future readers (or future me) get clearer
  failure surfaces.

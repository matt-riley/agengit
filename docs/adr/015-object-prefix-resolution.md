# ADR 015: Scalable object prefix resolution

**Status:** Implemented
**Date:** 2026-05-25

## Context

`src/store/object.zig:97–123` implements `resolvePrefix(prefix)` by walking
the entire `.agit/objects/` tree looking for files whose hash starts with
the requested prefix. This is fine for a store with a few hundred objects
but it is linear in store size, and `resolvePrefix` is on the hot path for
every `agit show <short-hash>`, `agit cat`, and `agit blame`.

For long-running repositories — exactly the workload agit is designed for —
this becomes the slowest part of read commands well before any other limit
binds.

The git equivalent uses sharded directories (`objects/ab/cdef...`), and we
already shard, but resolution still scans every shard for each lookup.

## Decision

1. **Use the shard prefix as a directory key.** If the user passes a prefix
   of length ≥ 2, only scan `.agit/objects/<first-two>/`. This is the
   common case and turns the lookup into a `readdir` of one directory.
2. **Cache shard contents** in the SQLite index. Add an `objects` table:
   ```sql
   CREATE TABLE objects (
     hash TEXT PRIMARY KEY,
     kind TEXT NOT NULL,
     size INTEGER NOT NULL,
     created_at INTEGER NOT NULL
   );
   ```
   Every object write inserts a row; resolution becomes a `SELECT hash FROM
   objects WHERE hash LIKE ?1 LIMIT 2` (LIMIT 2 to detect ambiguity).
3. **Reindex rebuilds the table** by walking the object store once. This
   is a one-time cost amortised across all future reads.
4. **Fall back to the filesystem** if the index is missing, corrupt, or
   the user passed `--no-index`. Filesystem mode keeps `agit cat` working
   when SQLite is unavailable.

## Plan

1. Add the `objects` table and migration in `src/store/index.zig`.
2. Update `src/store/object.zig:writeObject` to insert into the table
   inside the same transaction as the step insert (ADR 007).
3. Replace `resolvePrefix` with an index-first lookup; keep the
   filesystem walk as a fallback.
4. Update `agit reindex` to populate the `objects` table.
5. Add a benchmark that resolves 10k random prefixes against stores of
   100, 10k, 1M objects.

## Testing

- Unit test: insert N objects with known hashes, resolve unique and
  ambiguous prefixes, assert correct results and ambiguity detection.
- Unit test: drop the `objects` table, assert filesystem fallback still
  resolves.
- Benchmark: resolution time stays sub-millisecond up to at least 1M
  objects.
- Integration test: ambiguous prefix prints both candidates and exits
  non-zero with a clear message.

## Risks and tradeoffs

- Extra SQLite write per object insert. Negligible compared to the
  object write itself (which is the durable filesystem op).
- The cache can drift if someone hand-edits `.agit/objects/`. The
  filesystem fallback covers this; `agit doctor` will flag it as a
  reindex candidate.
- Schema migration adds one more reason to bump store version; coordinated
  with the migration introduced in ADR 007.

## Consequences

- Read commands stay fast as repositories age, which is the whole
  point of a long-running session log.
- A future "search by content" feature (out of scope) has a natural
  home in the same table.
- Reindex becomes more important as the source of truth for the cache;
  this aligns with ADR 007's reconcile-on-open behaviour.

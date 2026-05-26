# ADR 021: Packfiles and delta compression

**Status:** Implemented
**Date:** 2026-05-25

## Context

`agit` currently stores every unique file version as a full, compressed-by-default
(via filesystem or manually) blob. Because `agit` snapshots the entire
workspace on every turn, small changes to large files result in nearly identical
blobs being stored multiple times.

While this is simple and robust, it is storage-inefficient for long-running
sessions where the same few files are edited repeatedly. Git solves this using
"packfiles" and delta compression (storing only the changes between versions).

## Decision

Introduce a "pack" format for storing objects:

1. **Object Indirection:** The `Store` read path checks for a loose object in
   `.agit/objects/` first, then falls back to packfiles in
   `.agit/objects/pack/`. SQLite keeps packed-object metadata as a query
   accelerator, but the `.pack` files remain self-describing so `agit reindex`
   can rebuild metadata from disk truth.
2. **Delta Encoding:** Packfiles may store either full objects or one-level blob
   deltas. Delta candidates are chosen from adjacent revisions of the same path
   in session history so the packed representation stays safe and predictable.
3. **Pack Generation:** Packs are generated during `agit gc` (ADR 020). Reachable
   loose objects are grouped into a deterministic packfile, then the loose
   copies are removed and the index is rebuilt from the resulting loose+packed
   store state.
4. **Transparency:** The `Store.writeBlob` and `Store.readBlob` APIs remain
   unchanged. Writes still create loose objects; reads, reindex, fsck, and gc
   all understand packed objects transparently.

## Plan

1. Define a self-describing `.pack` format under `.agit/objects/pack/` with per-entry
   hashes, encoding metadata, CRC32 checks, and enough structure for `agit reindex`
   to scan it without trusting SQLite.
2. Update `src/store/index.zig` to track packed-object metadata while keeping the
   `objects` table authoritative for object existence checks and prefix lookup.
3. Implement delta reconstruction and pack scanning in `src/store/pack.zig`.
4. Update `agit gc`, `agit reindex`, and integrity scanning so packed stores stay
   readable, rebuildable, and verifiable after loose objects are removed.

## Testing

- Unit test: verify that a delta object + its base reconstructs the original
  bytes perfectly.
- Integration test: write two large versions of the same file with a 1-line
  change, run a packing pass, and assert that the resulting packfile is smaller
  than the two loose blobs combined.
- Reindex test: rebuild the object index from packfiles alone and assert that
  packed-object metadata is restored.

## Risks and tradeoffs

- **Complexity:** Packfiles and deltas are significantly more complex than
  loose objects.
- **Read Latency:** Reconstructing even a shallow delta is slower than reading
  a single loose file. The initial implementation caps chains at one delta hop
  per object to keep reads and integrity checks simple.
- **Corrupt Packs:** A single corrupted packfile can lose many objects.
  We will include CRC32 checks for every object entry in the pack.

## Consequences

- Significant reduction in disk usage for active repositories (often 10x
  or more).
- `agit` storage behavior becomes much closer to `git`, making it more
  sustainable for enterprise-scale repositories.
- `agit gc` becomes a slightly more heavyweight operation.

# ADR 021: Packfiles and delta compression

**Status:** Proposed
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

1. **Object Indirection:** The `Store` read path will first check for a loose
   object in `.agit/objects/`, then check the `index.db` to see if the object
   is stored within a packfile in `.agit/objects/pack/`.
2. **Delta Encoding:** Within a packfile, objects can be stored either as
   "base" objects (full content) or "delta" objects (a reference to a base
   plus a patch).
3. **Pack Generation:** Packs are generated during `agit gc` (ADR 020). Loose
   objects are combined into a packfile, and delta compression is applied
   using a simple algorithm (e.g., similar to Git's `vcdiff`).
4. **Transparency:** The `Store.writeBlob` and `Store.readBlob` APIs remain
   unchanged. Writing always creates a loose object; reading handles the
   lookup and reconstruction.

## Plan

1. Define the `.pack` (data) and `.idx` (offset index) file formats.
2. Update `src/store/index.zig` to track which packfile and offset contains
   an object.
3. Implement delta reconstruction in `src/store/object.zig`.
4. Implement the packing engine in `src/store/pack.zig`. This includes
   sliding-window delta compression.
5. Update `agit gc` to trigger a repacking pass that converts loose objects
   into packs.

## Testing

- Unit test: verify that a delta object + its base reconstructs the original
  bytes perfectly.
- Integration test: write two versions of a 1MB file with a 1-line change,
  run a packing pass, and assert that the resulting packfile is significantly
  smaller than 2MB.
- Benchmark: measure the latency of reading a loose object vs. a packed
  object vs. a deeply delta-compressed object.

## Risks and tradeoffs

- **Complexity:** Packfiles and deltas are significantly more complex than
  loose objects.
- **Read Latency:** Reconstructing a delta chain takes more CPU than
  reading a single file. We will cap the maximum delta chain depth (e.g.,
  50 versions).
- **Corrupt Packs:** A single corrupted packfile can lose many objects.
  We will include CRC32 checks for every object entry in the pack.

## Consequences

- Significant reduction in disk usage for active repositories (often 10x
  or more).
- `agit` storage behavior becomes much closer to `git`, making it more
  sustainable for enterprise-scale repositories.
- `agit gc` becomes a slightly more heavyweight operation.

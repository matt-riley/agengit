# ADR 016: Snapshot, diff, and blame performance

**Status:** Implemented
**Date:** 2026-05-25

## Context

Three hot paths allocate and copy more than they need to:

1. **Snapshot** — `src/store/snapshot.zig:55–75` calls `statFile` and then
   `readFileAlloc` on every file. Two syscalls per file plus a full buffer
   allocation for each one. On a snapshot pass over a moderate repo this
   doubles syscall count and peaks memory at the size of the largest file.
2. **Diff** — `src/store/diff.zig:43–84` allocates a slice per line plus
   intermediate arrays for the longest-common-subsequence pass. For large
   files (tens of thousands of lines) this allocates aggressively and
   doesn't reuse buffers between calls.
3. **Blame** — `src/store/blame.zig:56–85` builds per-line attribution
   tables by copying line content into fresh allocations. Blame is read
   often via `agit blame <file>`.

None of these is broken; they are just wasteful in the steady-state read
path. As the store grows and snapshots get more frequent, the cost
compounds.

## Decision

1. **Single-pass snapshot reads.** Replace the `stat` + `readFileAlloc`
   pair with a single open + `readAll` into a reusable buffer pool. Size
   is taken from the read result; an explicit cap (default 16 MiB per
   file, configurable) bounds memory.
2. **Skip binary files by content sniff** rather than by always reading
   first. Read the first 8 KiB, detect binary via NUL byte presence or
   high-bit ratio, stop early if binary unless the user explicitly opts in.
3. **Diff allocator scope.** Diff routines take an arena allocator passed
   by the caller; the arena resets between files. Internal line slices
   borrow from a shared input buffer rather than copying.
4. **Blame line table** stores line offsets and a back-reference into the
   buffer, not copies. The buffer lives for the duration of the blame
   call.
5. **Size caps** on diff and blame: files above a configurable threshold
   (default 5 MiB) produce a summary line instead of a full diff/blame.
   The user can override with `--no-limits`.

## Plan

1. Add `src/util/buf_pool.zig` — a thread-local pool of byte buffers
   sized by power-of-two.
2. Refactor `snapshot.zig` to use single-pass reads + the pool. Add
   binary sniff in `src/store/snapshot.zig:isBinary`.
3. Refactor `diff.zig` and `blame.zig` to take `std.heap.ArenaAllocator`
   and to operate over slice offsets, not copies.
4. Add size caps and the `--no-limits` flag to `cli/blame.zig` and any
   diff-rendering command.
5. Add a benchmark target `bench-store` covering snapshot/diff/blame on
   a synthetic repo of 1k files.

## Testing

- Unit tests verifying binary sniff against a corpus of known
  text/binary files.
- Diff/blame correctness tests unchanged (the refactor must not change
  output).
- Microbenchmark: snapshot a 1k-file repo, baseline vs new; expect
  ≥40% fewer syscalls and ≥30% reduction in peak RSS.
- Test that size caps trigger the summary path and that `--no-limits`
  bypasses them.

## Risks and tradeoffs

- Single-pass reads lose the `stat`-first size pre-check; we instead
  cap per-file reads. A pathological huge file is rejected by the cap
  rather than triggering a giant alloc.
- Arena allocators change ownership semantics; callers must understand
  that returned slices live only until arena reset. Documented inline.
- Size caps change command output for very large files; we document
  this in `--help` and in the README's `blame` section.

## Consequences

- Snapshot, diff, and blame all get measurably faster and lighter.
- Memory usage of read commands stays bounded even on repos with very
  large files.
- A buffer pool exists for future hot paths to reuse.
- A small behaviour change (size caps) is documented and overridable,
  which is the right default for a CLI that wraps long-running sessions.

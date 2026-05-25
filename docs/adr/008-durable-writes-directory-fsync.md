# ADR 008: Durable writes — directory fsync on atomic replace

**Status:** Accepted
**Date:** 2026-05-25

## Context

Several store paths use the standard "write tmp, fsync file, rename onto
target" pattern:

- `src/store/ref.zig:32` — ref tip writes
- `src/store/object.zig:71` — object store inserts
- `src/store/snapshot.zig:110` — snapshot manifests
- `src/recorder.zig:185` — hook-error log entries

In every case the *file* is fsynced but the *parent directory* is not. On
ext4, xfs, btrfs, and APFS, a `rename()` is only guaranteed durable after the
directory inode itself is fsynced. A crash between rename and the next
implicit directory flush can lose the newly committed file even though
`fsync(fd)` returned success.

This is the textbook safety bug for content-addressed stores. We have already
hit one anecdotal report of "the step appeared in `agit status` and then
vanished after a forced reboot," which is consistent with this failure mode.

## Decision

Introduce a `util.fs.atomicReplace` helper that:

1. Writes content to `tmp_path`.
2. Calls `fsync(tmp_fd)`.
3. Calls `rename(tmp_path, target_path)`.
4. Opens the parent directory and calls `fsync(dir_fd)`.
5. Closes both handles.

Every existing call site that does atomic replace migrates to this helper.

Directory fsync is also added after `link()` calls used for content-addressed
inserts (`src/store/object.zig` hard-link path).

## Implementation

1. Added `src/util/fs.zig` with durable helpers:
   - `atomicReplace`
   - `linkDurable`
   - `renameDurable`
   - `syncDir`
2. Migrated atomic write/link call sites in:
   - `src/store/ref.zig`
   - `src/store/object.zig`
   - `src/store/snapshot.zig`
   - `src/recorder.zig`
   - `src/cli/init.zig`
   - `src/cli/uninstall.zig`
3. Added `AGIT_FSYNC=0` support (default remains fsync enabled) initialized in
   `src/main.zig`.
4. Added coverage and tooling:
   - `tests/e2e/record_replay/durable_writes.zig`
   - `bench/durable.zig`
   - `zig build bench-durable` build step and README guidance.

## Testing

- Unit tests using `std.fs.Dir` against tempdir to assert directory entries
  exist after the helper returns (sanity, not a true crash test).
- E2E durability flow test in `tests/e2e/record_replay/durable_writes.zig`
  asserts that finalized refs/objects are readable via CLI paths after
  recording.
- Microbenchmark `zig build bench-durable` to track the cost; we expect a
  few hundred microseconds per operation on a local SSD.

## Risks and tradeoffs

- Directory fsync has real cost on rotational disks and some FUSE
  filesystems. We accept this for v1; if users complain we expose
  `AGIT_FSYNC=batch` to amortise across a hook batch.
- Some filesystems (tmpfs) ignore fsync; tests must not assume durability on
  tmpfs.
- macOS `fcntl(F_FULLFSYNC)` is stronger but slower than `fsync()`. v1
  uses `fsync()`; we revisit if a user reports data loss on Apple SSDs.

## Consequences

- Store writes survive crash and forced reboot, which matters because the
  whole point of agit is to be the "little black box" that survives the
  session.
- A single helper makes future audits easy: grep for `atomicReplace` and
  everything that should be durable is.
- Slight per-write latency increase, masked by hook process startup time
  which dominates anyway.

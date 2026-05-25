# ADR 008: Durable writes — directory fsync on atomic replace

**Status:** Proposed
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

## Plan

1. Add `src/util/fs.zig` with:
   - `pub fn atomicReplace(dir: std.fs.Dir, tmp_name, final_name) !void`
   - `pub fn syncParentDir(path: []const u8) !void`
   - `pub fn linkDurable(src: std.fs.Dir, src_name, dst: std.fs.Dir, dst_name) !void`
2. Migrate call sites:
   - `src/store/ref.zig:writeRefToPath`
   - `src/store/object.zig:writeObject` and `linkObject`
   - `src/store/snapshot.zig:writeManifest`
   - `src/recorder.zig` hook-error log append
   - `src/util/atomic_json.zig` (from ADR 006)
3. Add a `--no-fsync` flag (or env var `AGIT_FSYNC=0`) used only in tests and
   benchmarks. Production code always syncs.
4. Document the durability guarantee in `docs/adr/001-store-directory.md` as
   a forward reference.

## Testing

- Unit tests using `std.fs.Dir` against tempdir to assert directory entries
  exist after the helper returns (sanity, not a true crash test).
- A crash-injection test: spawn `agit` under `strace`/`ltrace` (Linux),
  fault-inject after `rename` but before any subsequent syscall, reboot the
  test fs (via `tmpfs` + drop_caches in CI is sufficient), assert objects
  are still findable.
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

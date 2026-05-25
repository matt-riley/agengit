# ADR 009: Robust file locking for concurrent hook writers

**Status:** Proposed
**Date:** 2026-05-25

## Context

`src/util/file_lock.zig` implements an advisory PID-file lock used to
serialise writers against `.agit/`. Multiple hook processes can fire
simultaneously — for example, Claude `PostToolBatch` while Codex `Stop` is
still finalising — and the lock keeps ref CAS sane.

Current behaviour (lines ~73–111):

- Acquire writes `pid\n` to the lock file, then returns without `fsync`.
- Release calls `delete` and ignores any error.
- Stale lock detection compares the on-disk PID against the live process
  table but does not validate that the PID belongs to an `agit` process.

Concrete failure modes:

1. A crashed hook leaves a PID file. If that PID is later reused by some
   unrelated process (very common on long-lived shells), the next hook
   sees a "live" lock and blocks or fails.
2. The lack of `fsync` after PID write means a crash between write and
   the next caller's read can show empty PID content — current code treats
   that as a valid lock and stalls.
3. Release errors (permission, ENOENT) are silent, masking real bugs.

## Decision

1. **Lock content is structured**: a single JSON line with `{pid, started_at,
   exe_path, hostname}`. The lock is considered live only if all four match
   a process currently running `agit` on this host.
2. **fsync after PID write** before returning from `acquire`.
3. **Release surfaces errors** in non-release builds and logs them via the
   hook-error log in release builds.
4. **Stale lock takeover** is automatic when:
   - the PID does not exist; or
   - the PID exists but the executable path does not match `exe_path`; or
   - the lock is older than a configurable timeout (default 5 minutes for
     hook writes, which is generous given hook duration is typically under
     a second).
5. **Lock acquisition is bounded** with exponential backoff and an explicit
   timeout (default 10 seconds). Exceeding the timeout is a typed error,
   not a hang.

## Plan

1. Extend `src/util/file_lock.zig`:
   - Replace plain `pid\n` content with a `LockRecord` JSON struct.
   - Add `isProcessOurs(pid, exe_path) !bool` using `/proc/<pid>/exe` on
     Linux and `proc_pidpath` on macOS.
   - Add `acquireWithTimeout(opts: AcquireOpts) !Lock` and deprecate the
     timeout-less variant.
2. Add hook-error logging on release failures using the existing
   `recorder.zig` hook-error path.
3. Expose `agit doctor --locks` listing any locks currently held and their
   age.
4. Update callers in `src/recorder.zig` and `src/store/store.zig` to use the
   new bounded acquire and to surface lock-timeout errors clearly.

## Testing

- Unit tests for `LockRecord` round-trip.
- Tests for stale lock detection: forge a lock with a PID belonging to
  `init`/`launchd` and assert takeover.
- Concurrency test: spawn N parallel `agit claude-hook` processes against
  the same store and assert all finalize successfully with no corruption
  (also exercised in ADR 014 integration suite).
- Timeout test: hold the lock manually, run a hook with
  `AGIT_LOCK_TIMEOUT_MS=100`, assert it exits with a clear error.

## Risks and tradeoffs

- The platform-specific PID check is more code than the current naive
  comparison. We hide it behind a single function and fall back to
  PID-only on unsupported platforms.
- Bounded waits mean a slow disk can cause hook write failures where
  before they would just take longer. The default 10s ceiling is well
  above realistic latency.
- Structured JSON lock content is technically a wire-format change. No
  external tools read these locks today, so backwards compatibility is
  not a concern.

## Consequences

- Stale-lock-after-crash stops blocking real work.
- The recorder gains a useful "what's holding the lock right now" signal
  via `agit doctor`.
- Failures become observable instead of silent hangs.
- The system behaves correctly under concurrent multi-agent recording,
  which is the whole point of supporting Claude + Codex + Gemini
  simultaneously.

# Plan 005: Stop silently overwriting blame when prior state is unavailable

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat bae6a6c..HEAD -- src/store/store.zig`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `bae6a6c`, 2026-06-20

## Why this matters

`Store.recordStepBlame()` is supposed to compute incremental blame against the previous recorded version. When the prior blame object or blob cannot be read, the current code silently falls back to treating the file as brand new ("all lines introduced by this step"). That loses attribution history for that file until the next full `agit reindex`. Worse, it writes a new, incorrect blame row without signaling that anything went wrong.

The fix is to mark blame as needing a reindex and return an error instead of producing a misleading blame map.

## Current state

- `src/store/store.zig:407-477` — `recordStepBlame()` contains two silent fallbacks:

```zig
            const new_blob = self.readBlob(io, arena, new_blob_hash) catch continue;   // line ~430
...
            if (latest) |prior| {
                if (self.loadPriorBlame(io, arena, prior)) |loaded| {                  // line ~440
                    ...
                } else |_| {}                                                         // prior load error swallowed
            }
```

- `src/store/store.zig:483-503` — `loadPriorBlame()` is the helper that can fail when the prior blob or blame object is missing.

- `src/recorder.zig` already sets the `blameNeedsReindex` flag before calling `recordStepBlame()` and leaves it set if the call errors.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Typecheck / test | `zig build test` | exit 0, all tests pass |
| Format | `zig build fmt` | exit 0 |

## Scope

**In scope**:
- `src/store/store.zig`
- Tests inside `src/store/store.zig`

**Out of scope**:
- `src/recorder.zig` (caller already handles errors correctly).
- `src/store/blame.zig` (the diff/blame computation itself is fine).

## Steps

### Step 1: Make missing prior state an error

In `src/store/store.zig`, change the `else |_| {}` branch in `recordStepBlame()` so that a failure to load prior blame marks blame as needing reindex and returns an error.

Target shape:

```zig
            if (latest) |prior| {
                const loaded = self.loadPriorBlame(io, arena, prior) catch |err| {
                    try self.setBlameNeedsReindex(true);
                    return err;
                };
                if (loaded.lines.len == loaded.blame.lines.len) {
                    old_lines = loaded.lines;
                    old_blame = loaded.blame;
                } else {
                    try self.setBlameNeedsReindex(true);
                    return error.BlameLengthMismatch;
                }
            }
```

**Verify**: `zig build test` still passes.

### Step 2: Treat unreadable new blobs as an error

Change the new-blob read so that a missing/corrupt blob returns an error rather than silently skipping the file. Keep the existing size/binary/placeholder checks after the read succeeds.

Target shape:

```zig
            const new_blob = self.readBlob(io, arena, new_blob_hash) catch |err| {
                try self.setBlameNeedsReindex(true);
                return err;
            };
```

**Verify**: `zig build test` still passes.

### Step 3: Add a public error code if needed

If `error.BlameLengthMismatch` is not already in scope, make it available. You may add it to a public error set or use an existing appropriate error. The key is that the error propagates to `Recorder.recordBlameForStep()`, which logs it and leaves `blameNeedsReindex` set.

**Verify**: `zig build test` still passes.

### Step 4: Add regression tests

Add a test in `src/store/store.zig` that:

1. Creates a store and a session with a step for `path = "src/file.txt"`.
2. Records blame for that step so that a `blame_maps` row exists.
3. Deletes the blame object from `.agit/objects/` (using the stored `blame_hash`) or deletes the prior blob object.
4. Calls `store.recordStepBlame()` for a second step that changed the file.
5. Asserts the call returns an error and that `store.blameNeedsReindex()` is `true` afterwards.
6. Asserts that no new `blame_maps` row was written for the second step.

A second, simpler test should mirror the existing blame success test and confirm normal incremental blame still works.

Model on the existing blame test inside `src/store/store.zig` near `recordStepBlame`.

## Test plan

- `test "recordStepBlame marks reindex when prior blame object is missing"`
- `test "recordStepBlame still computes incremental blame when prior state exists"` (existing happy-path test, ensure it still passes)

## Done criteria

- [ ] Missing/corrupt prior blame causes `recordStepBlame()` to return an error and set the reindex flag.
- [ ] Missing/corrupt new blob causes `recordStepBlame()` to return an error and set the reindex flag.
- [ ] Normal incremental blame (all objects present) still works.
- [ ] New regression test passes.
- [ ] `zig build test` exits 0.
- [ ] `zig build check-fmt` exits 0.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- `recordStepBlame()` is called from additional paths that are not prepared for it to return an error.
- The new error path causes finalize to abort instead of logging and continuing (it should not; `Recorder.recordBlameForStep()` catches the error).

## Maintenance notes

This makes the blame system conservative: it prefers stale-but-correct data over freshly-computed-but-wrong data. Future changes that add new recoverable blame failure modes should follow the same pattern (set reindex flag + error) unless they can safely fall back to a correct result.

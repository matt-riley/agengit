# Plan 002: Sync reindex with the blame timestamp counter and clear stale meta

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat bae6a6c..HEAD -- src/store/index.zig src/cli/reindex.zig src/store/store.zig`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `bae6a6c`, 2026-06-20

## Why this matters

`agit reindex` rebuilds the in-memory structures but leaves the SQLite `meta` table untouched. Two consequences:

1. Stale `session::*::last_ref_hash` keys survive for sessions whose refs have been removed.
2. The `blame.last_step_timestamp` counter is never reset to the actual maximum historical step timestamp. After a reindex, a new finalize can obtain a timestamp lower than an existing historical step, causing blame and timeline ordering to interleave.

This plan makes reindex leave `meta` in a clean, consistent state.

## Current state

- `src/store/index.zig:384-397` — `Index.truncate()` deletes data tables but **not** `meta`:

```zig
    pub fn truncate(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();
        try self.db.execNoArgs("delete from search_entries");
        try self.db.execNoArgs("delete from tool_calls");
        try self.db.execNoArgs("delete from messages");
        try self.db.execNoArgs("delete from steps");
        try self.db.execNoArgs("delete from sessions");
        try self.db.execNoArgs("delete from blame_maps");
        try self.db.execNoArgs("delete from packed_objects");
        try self.db.execNoArgs("delete from objects");
        try self.db.commit();
    }
```

- `src/cli/reindex.zig:138-180` — `rebuildBlame()` replays every step to rebuild blame but never touches `blame.last_step_timestamp`.
- `src/store/store.zig:375-383` — the timestamp counter helpers:

```zig
    pub fn monotonicTimestamp(self: *Store, now_ms: i64) !i64 {
        const last = try self.index.readMetaCounter(blame_last_timestamp_key);
        return if (now_ms > last) now_ms else last + 1;
    }

    pub fn advanceBlameTimestamp(self: *Store, timestamp: i64) !void {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "{d}", .{timestamp});
        try self.index.metaSet(blame_last_timestamp_key, str);
    }
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Typecheck / test | `zig build test` | exit 0, all tests pass |
| Format | `zig build fmt` | exit 0 |

## Scope

**In scope**:
- `src/store/index.zig`
- `src/cli/reindex.zig`
- `src/store/store.zig` (only for reading the key constant if needed; no edits required)

**Out of scope**:
- Any change to finalize logic.
- Any change to the schema/migrations.

## Steps

### Step 1: Clear `meta` in `Index.truncate`

In `src/store/index.zig`, add a `delete from meta` statement to `Index.truncate()`, **after** the existing deletes and inside the same transaction. Keep `schema_migrations` untouched.

Target shape:

```zig
    pub fn truncate(self: Index) !void {
        try self.db.transaction();
        errdefer self.db.rollback();
        try self.db.execNoArgs("delete from search_entries");
        try self.db.execNoArgs("delete from tool_calls");
        try self.db.execNoArgs("delete from messages");
        try self.db.execNoArgs("delete from steps");
        try self.db.execNoArgs("delete from sessions");
        try self.db.execNoArgs("delete from blame_maps");
        try self.db.execNoArgs("delete from packed_objects");
        try self.db.execNoArgs("delete from objects");
        try self.db.execNoArgs("delete from meta"); // NEW
        try self.db.commit();
    }
```

**Verify**: `zig build test` still passes.

### Step 2: Add a max-timestamp helper to `Index`

In `src/store/index.zig`, add:

```zig
    pub fn maxStepTimestamp(self: Index) !?i64 {
        const row = try self.db.row("select max(timestamp) from steps", .{}) orelse return null;
        defer row.deinit();
        return row.get(?i64, 0);
    }
```

Place it near the other step-count helpers.

**Verify**: `zig build test` still passes.

### Step 3: Update `rebuildBlame` to sync the counter

In `src/cli/reindex.zig`, after the replay loop in `rebuildBlame()` and before clearing the dirty flag, set the blame timestamp counter to the current maximum step timestamp. The constant `blame_last_timestamp_key` is already exported from `store_mod` as `store_mod.blame_last_timestamp_key`.

Target shape (added after the `for (steps.items)` loop):

```zig
    if (try store.index.maxStepTimestamp()) |max_ts| {
        try store.advanceBlameTimestamp(max_ts);
    } else {
        try store.index.metaDelete(store_mod.blame_last_timestamp_key);
    }

    if (!any_failed) try store.setBlameNeedsReindex(false);
```

**Verify**: `zig build test` still passes.

### Step 4: Add tests

1. In `src/store/index.zig`, add a test inside the existing `test "index truncate"` or as a new adjacent test that sets a meta key, calls `idx.truncate()`, and asserts the key is gone.

2. In `src/cli/reindex.zig`, add a regression test:

   - Open a store and finalize a step with `timestamp = 5000` by writing/committing a step directly (use `store.commitFinalizedStep`).
   - Run `reindex(io, gpa, &store)`.
   - Call `store.monotonicTimestamp(1000)` and assert the returned value is `5001` (not `1000`).

**Verify**: `zig build test` passes and the new tests execute.

## Test plan

- `test "truncate clears meta"` — meta key created and then removed after `Index.truncate()`.
- `test "reindex advances blame timestamp counter"` — regression test for the interleaving bug.

Model new tests on the existing test blocks in the same files (e.g. `test "index truncate"` in `src/store/index.zig` and `test "reindex repairs missing rows from objects and refs"` in `src/cli/reindex.zig`).

## Done criteria

- [ ] `Index.truncate()` deletes from `meta`.
- [ ] `Index.maxStepTimestamp()` exists and returns the correct `?i64`.
- [ ] `rebuildBlame()` advances `blame.last_step_timestamp` to `max(steps.timestamp)` (or deletes the key if no steps).
- [ ] New regression tests pass.
- [ ] `zig build test` exits 0.
- [ ] `zig build check-fmt` exits 0.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- `Index.truncate()` already clears `meta` (the live code drifted).
- A test expects a meta key to survive `truncate()`.
- The reindex counter value after the fix is still not equal to the max historical timestamp.

## Maintenance notes

`Index.truncate()` is only used by reindex paths, so clearing `meta` is safe. If any future feature needs a meta key to survive reindex, that key must be explicitly re-written after truncation.

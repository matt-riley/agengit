# Plan 002: Cache repeated tree reads in `agit stats` file-tally loop

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 3b45f66..HEAD -- src/cli/stats.zig`
> If `src/cli/stats.zig` changed since this plan was written, compare the
> "Current state" excerpt against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `3b45f66`, 2026-06-21

## Why this matters

`agit stats`'s "most changed paths" file tally (`buildFileTally` in `src/cli/stats.zig`) reads each step's tree, and — for any step with a parent — also reads the *parent step object* and the *parent's tree*, for up to `file_tally_step_cap = 500` steps. In a linear session history (the common case: one agent working through one session), step N's parent tree is the same tree object as step N-1's *current* tree, which was already read one iteration earlier. The loop re-reads it from disk and re-parses it every time instead of reusing the already-parsed value, and it always reads the full parent `Step` object just to discover its `tree` hash even though the index's `steps` table already stores `tree_hash` for every row (see `src/store/index.zig:128`, `StepRow.tree_hash` at `src/store/index/rows.zig`). Caching parsed trees by hash, and looking up the parent's tree hash from the already-loaded `StepRow` list instead of re-reading the parent `Step` object, removes most of the redundant I/O on large histories without changing the command's output.

## Current state

- `src/cli/stats.zig` — implements `agit stats`. The relevant function is `buildFileTally` (the loop starts around line 184).
- `src/cli/stats.zig:175-210` today:
  ```zig
  defer store_mod.freeStepRows(gpa, steps);

  var counts = std.StringHashMap(usize).init(gpa);
  defer {
      var it = counts.keyIterator();
      while (it.next()) |key| gpa.free(key.*);
      counts.deinit();
  }

  for (steps) |step| {
      var current_tree = try readTreeOrExit(io, gpa, store, step.tree_hash);
      defer current_tree.deinit();

      var parent_step: ?std.json.Parsed(store_mod.Step) = null;
      defer if (parent_step) |*parsed| parsed.deinit();
      var parent_tree: ?std.json.Parsed(store_mod.Tree) = null;
      defer if (parent_tree) |*parsed| parsed.deinit();

      const old_entries: []const store_mod.TreeEntry = if (step.parent_hash) |parent_hash_hex| blk: {
          const parent_hash = try store_mod.Hash.fromHex(parent_hash_hex);
          parent_step = try store.readStep(io, gpa, parent_hash);
          parent_tree = try readTreeOrExit(io, gpa, store, parent_step.?.value.tree);
          break :blk parent_tree.?.value.entries;
      } else &.{};

      var comparison = try inspect_mod.compareTreeEntries(gpa, old_entries, current_tree.value.entries);
      defer comparison.deinit(gpa);
      for (comparison.entries) |entry| {
          if (entry.kind == .unchanged) continue;
          if (counts.getPtr(entry.path)) |count| {
              count.* += 1;
          } else {
              try counts.putNoClobber(try gpa.dupe(u8, entry.path), 1);
          }
      }
  }
  ```
- `steps` is `[]const store_mod.StepRow`, populated earlier in the function from `store.index.listStatsSteps(...)`. `StepRow` (defined via `src/store/index/rows.zig`, re-exported at `src/store/index.zig:1710`) has fields including `hash: []const u8`, `parent_hash: ?[]const u8`, and `tree_hash: []const u8` for **every** row — confirmed by `src/store/index.zig:1264` and `:1335` (`select hash, turn_id, parent_hash, tree_hash, ...`). This means the parent's `tree_hash` can be found by looking up `step.parent_hash` against the other rows already in `steps`, without reading the parent `Step` object from the object store at all — **unless** the parent step falls outside the `steps` slice (e.g., it's step #501 when the cap is 500, or it belongs to a different session window than what `listStatsSteps` returned). In that case, falling back to `store.readStep` is still correct and necessary.
- `readTreeOrExit` (defined elsewhere in `src/cli/stats.zig`, search for `fn readTreeOrExit`) wraps `store.readTree` with the command's standard exit-on-error diagnostic. Keep using it for new tree reads — do not change its error-handling behavior.
- `store.readStep` / `store.readTree` are object-store reads (`src/store/store.zig`); each one parses JSON from disk. There is no existing batch API for tree reads (`queryStepMetaBatch` in `src/store/index.zig:881` batches *index* metadata, not object-store tree contents — do not attempt to extend it for this; it's out of scope, see below).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Unit tests | `zig build test` | 0 failed |
| E2E tests | `zig build test-e2e` | all pass |
| Full check | `zig build check` | exit 0 |
| Manual check | `zig build && ./zig-out/bin/agit stats` (run inside this repo, which has its own `.agit/`) | output matches pre-change output (see Step 3) |

## Scope

**In scope** (the only file you should modify):
- `src/cli/stats.zig` — `buildFileTally` function only.

**Out of scope** (do NOT touch, even though related):
- `src/store/index.zig` — do not add a new batch query method; this plan solves the problem with in-memory caching and reuse of data already fetched by `listStatsSteps`, not a new index query.
- `inspect_mod.compareTreeEntries` and its semantics — unchanged.
- Any other `agit stats` subcommand or output section (tool-usage tally, etc.) — only the file-path tally loop is in scope.
- `file_tally_step_cap` value (500) — do not change it.

## Git workflow

- Branch: `advisor/002-batch-stats-tree-reads`
- Commit message: `perf: cache parsed trees and reuse step-row tree hashes in agit stats file tally`
- Do NOT push or open a PR unless explicitly instructed.

## Steps

### Step 1: Build a hash → `StepRow` lookup before the loop

Immediately after `steps` is populated (before the `for (steps) |step|` loop), build a `std.StringHashMap(store_mod.StepRow)` (or just a `std.StringHashMap([]const u8)` mapping step hash → `tree_hash`, which is all you actually need) keyed by each row's `hash` field, covering all of `steps`. Free/deinit it after the loop with `defer`.

This lets you look up a parent's `tree_hash` directly when the parent happens to be one of the rows already loaded, instead of always calling `store.readStep`.

**Verify**: code compiles — `zig build` → exit 0 (no test yet; this step only adds the map, doesn't wire it in).

### Step 2: Add a tree cache keyed by tree hash, and rewrite the loop to use both lookups

Add a second map before the loop: `var tree_cache = std.StringHashMap(std.json.Parsed(store_mod.Tree)).init(gpa);` with a `defer` that iterates its values calling `.deinit()` on each `std.json.Parsed(Tree)` before `tree_cache.deinit()`.

Add a small local helper (a nested function or a `getOrReadTree` closure-equivalent — Zig doesn't have closures, so write it as a regular function taking `io`, `gpa`, `store`, `tree_cache: *std.StringHashMap(...)`, and `tree_hash: []const u8`, returning `*const store_mod.Tree`) that:
1. Looks up `tree_hash` in `tree_cache`; if present, returns a pointer to the cached value's `.value`.
2. Otherwise calls `readTreeOrExit` to read it, stores the parsed result in the cache (duplicating `tree_hash` with `gpa.dupe(u8, tree_hash)` as the map key, since the cache outlives the current loop iteration's `step.tree_hash` slice lifetime — verify `StepRow.tree_hash` slices are stable for the lifetime of `steps`, which they are since `steps` isn't freed until the function returns), and returns a pointer to the newly-cached value.

Rewrite the loop body to:
1. Call the new helper for `step.tree_hash` to get `current_tree` (a `*const Tree`, not an owned `Parsed(Tree)` anymore — adjust `defer current_tree.deinit()` removal accordingly, since the cache now owns the lifetime).
2. For the parent: if `step.parent_hash` is non-null, first check the hash → `tree_hash` map from Step 1. If the parent hash is found there, call the same tree-cache helper with that `tree_hash` (no `store.readStep` needed). If the parent hash is **not** found in the map (parent falls outside the `steps` window), fall back to the existing behavior: `store.readStep` to get the parent's `tree_hash`, then the tree-cache helper for that hash.
3. Everything after obtaining `current_tree`'s and the parent's entries (the `compareTreeEntries` call and counting) stays identical.

**Verify**: `zig build test` → 0 failed (existing unit tests, if any, for stats.zig — check with `grep -n "^test \"" src/cli/stats.zig`; if none exist, this step has no unit-test gate yet, that's expected — covered by Step 3's e2e check instead).

### Step 3: Confirm output is unchanged via e2e tests and a manual run

**Verify**: `zig build test-e2e` → all pass, including any `tests/e2e/analytics/diff_stats.zig` cases (this file exercises `agit stats`; check it runs clean).

Additionally, run the built binary against this repo's own real `.agit/` store before and after your change and diff the output:
```sh
zig build
./zig-out/bin/agit stats > /tmp/stats-after.txt
git stash
zig build
./zig-out/bin/agit stats > /tmp/stats-before.txt
git stash pop
zig build
diff /tmp/stats-before.txt /tmp/stats-after.txt
```
**Verify**: `diff` produces no output (byte-identical).

## Test plan

- No new test file is required if `tests/e2e/analytics/diff_stats.zig` already exercises the file-tally path with multi-step sessions (check its contents first). If it does NOT cover a session with 3+ steps where step N's parent tree equals step N-1's current tree (the case this plan optimizes), add one case to that file modeled on its existing test structure, asserting the tally output is identical to what it would be without caching (i.e., assert specific path counts, not just "doesn't crash").
- Verification: `zig build test-e2e` → all pass, including the new/confirmed case.

## Done criteria

- [ ] `zig build check` exits 0
- [ ] `zig build test-e2e` exits 0
- [ ] Manual before/after `agit stats` diff on this repo's own `.agit/` store is empty
- [ ] `git status` shows only `src/cli/stats.zig` (and optionally `tests/e2e/analytics/diff_stats.zig`) modified
- [ ] `plans/README.md` status row for 002 updated to DONE

## STOP conditions

Stop and report back (do not improvise) if:
- `StepRow` does not actually have a `tree_hash` field stable across the rows returned by `listStatsSteps` (re-check `src/store/index.zig` around lines 1256–1350 if the schema looks different from the excerpt above).
- The before/after `agit stats` diff is non-empty for reasons other than nondeterministic ordering that already existed before your change (e.g., hashmap iteration order) — if the pre-existing output was already using a stable sort before printing, your change must preserve that; if you find the loop or final sort logic relies on read order in a way your caching changes, stop and report rather than reordering output.
- Memory ownership of `tree_cache` values becomes unclear (e.g., `Tree.deinit()` needs the same allocator that parsed it) — confirm `readTreeOrExit`'s allocator usage matches `gpa` before assuming the cache's `deinit` loop is correct.

## Maintenance notes

- If a future change adds more fields to `StepRow` needed elsewhere in this loop, the hash→tree_hash lookup map from Step 1 can be extended or reused.
- If `file_tally_step_cap` is ever raised significantly (e.g., to cover entire long-running sessions), this caching becomes proportionally more valuable since cache hit rate increases with session linearity — no further changes needed at that point, this plan's design already accounts for it.

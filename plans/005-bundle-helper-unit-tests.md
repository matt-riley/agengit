# Plan 005: Add unit tests for `bundle.zig`'s untested pure helper functions

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 3b45f66..HEAD -- src/store/bundle.zig`
> If `src/store/bundle.zig` changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `3b45f66`, 2026-06-21

## Why this matters

`src/store/bundle.zig` (875 lines) implements `agit export`/`agit import` bundle serialization, and currently has exactly one embedded `test "..."` block (`namespacedSessionIdAlloc appends bundle prefix`) despite containing several small, pure, easily-testable functions — most notably `isSafeRelativePath`, the path-traversal guard called at three validation sites during bundle import (`validateManifest`, `validatePrivacyReportPath`, `validateBundleObjects` — see `src/store/bundle.zig:604,612,627`) to reject manifest/object paths that could escape the bundle directory during extraction. A path-safety guard like this is exactly the kind of function that should have direct unit tests covering the boundary cases (`..`, absolute paths, empty segments, trailing slashes) rather than relying solely on whatever cases happen to be exercised indirectly by `tests/e2e/portable_bundle.zig`. The other pure helpers (`shouldReplaceRef`, `sessionMatchesWindow`'s pure branches, `computeBundleId`) are also untested at unit scope and are cheap to cover now.

## Current state

- `src/store/bundle.zig:860-869` — the function to test most carefully:
  ```zig
  fn isSafeRelativePath(path: []const u8) bool {
      if (path.len == 0) return false;
      if (std.fs.path.isAbsolute(path)) return false;
      var parts = std.mem.splitScalar(u8, path, '/');
      while (parts.next()) |part| {
          if (part.len == 0) return false;
          if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
      }
      return true;
  }
  ```
  Called from three validation sites (`src/store/bundle.zig:604, 612, 627`) — each rejects the corresponding manifest/object entry with `error.BundlePathInvalid` when this returns `false`.
- `src/store/bundle.zig:717-721` — `shouldReplaceRef`:
  ```zig
  fn shouldReplaceRef(replace_refs: []const SessionFilter, origin: []const u8, session_id: []const u8) bool {
      for (replace_refs) |ref_filter| {
          if (std.mem.eql(u8, ref_filter.origin, origin) and std.mem.eql(u8, ref_filter.session_id, session_id)) return true;
      }
      return false;
  }
  ```
- `src/store/bundle.zig:724-726` — `namespacedSessionIdAlloc` (already has one test at line 871; this plan does not need to add more unless you find an uncovered edge case, see Step 2):
  ```zig
  fn namespacedSessionIdAlloc(gpa: std.mem.Allocator, session_id: []const u8, bundle_id: []const u8) ![]u8 {
      return std.fmt.allocPrint(gpa, "{s}@import-{s}", .{ session_id, bundle_id[0..12] });
  }
  ```
- `src/store/bundle.zig:835-852` — `computeBundleId`:
  ```zig
  fn computeBundleId(
      gpa: std.mem.Allocator,
      selected: []const SelectedRef,
      created_at_ms: i64,
  ) ![hash_mod.hex_len]u8 {
      var seed = std.ArrayList(u8).empty;
      defer seed.deinit(gpa);

      var ts_buf: [32]u8 = undefined;
      const ts = try std.fmt.bufPrint(&ts_buf, "{d}", .{created_at_ms});
      try seed.appendSlice(gpa, ts);
      for (selected) |ref| {
          try seed.appendSlice(gpa, ref.path);
          try seed.append(gpa, 0);
          try seed.appendSlice(gpa, ref.head_hash);
          try seed.append(gpa, '\n');
      }
      return hash_mod.Hash.ofBytes(seed.items).toHex();
  }
  ```
  `SelectedRef` is defined elsewhere in this file (search `const SelectedRef = struct` or similar) — check its exact field names (`path`, `head_hash` are referenced above) before writing a test that constructs one.
- `src/store/bundle.zig:871-875` — the existing test, to match style/placement convention (tests live at the bottom of the file, near the functions they cover... actually this one test sits right after `isSafeRelativePath`'s definition, i.e. tests are interspersed near their target function, not all grouped at the file's end — follow this file's existing placement convention, not a different one):
  ```zig
  test "namespacedSessionIdAlloc appends bundle prefix" {
      const value = try namespacedSessionIdAlloc(std.testing.allocator, "sess", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
      defer std.testing.allocator.free(value);
      try std.testing.expectEqualStrings("sess@import-0123456789ab", value);
  }
  ```
- These functions are all private (`fn`, not `pub fn`), so tests must live inside `src/store/bundle.zig` itself (Zig test blocks in the same file can call private functions directly) — per `CLAUDE.md`'s testing layout: "Unit tests live in `test \"...\"` blocks directly in each `.zig` file."
- `src/main.zig` pulls all unit tests into the test binary via `_ = @import(...)` — confirm `bundle.zig` (or its containing module path) is already referenced there; if `store.zig` already imports `bundle.zig` and `store.zig` is referenced in `main.zig`, no new wiring is needed. Check with `grep -n "bundle" src/main.zig src/store/store.zig` before assuming.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Unit tests | `zig build test` | 0 failed, new tests counted in the total |
| Full check | `zig build check` | exit 0 |

## Scope

**In scope** (the only file you should modify):
- `src/store/bundle.zig` — add new `test "..."` blocks only. Do not change any non-test code, including the functions under test.

**Out of scope** (do NOT touch, even though related):
- `tests/e2e/portable_bundle.zig` — leave the existing e2e coverage as-is; this plan adds unit-level coverage alongside it, not a replacement.
- `exportBundle`, `importBundle`, or any function that performs I/O (these need the e2e harness, not unit tests, per this repo's testing layout — `CLAUDE.md` distinguishes unit tests for in-process logic from e2e tests that spawn the binary).
- Adding tests for `validateManifest`, `validatePrivacyReportPath`, `validateBundleObjects` themselves (the call sites) — only the pure helper functions they call are in scope; the call sites involve I/O-adjacent setup that's better covered by the existing e2e bundle tests.

## Git workflow

- Branch: `advisor/005-bundle-helper-unit-tests`
- Commit message: `test: add unit tests for bundle.zig path-safety and pure helper functions`
- Do NOT push or open a PR unless explicitly instructed.

## Steps

### Step 1: Add tests for `isSafeRelativePath`

Add a `test "isSafeRelativePath rejects unsafe paths"` and/or split into multiple focused tests (your choice — match this file's existing one-test-per-behavior granularity). Cover at minimum:
- Valid: `"objects/ab/cdef"` → `true`
- Valid: `"a"` → `true` (single safe segment)
- Invalid: `""` → `false` (empty path)
- Invalid: `"/etc/passwd"` → `false` (absolute path)
- Invalid: `"../escape"` → `false` (parent-dir segment)
- Invalid: `"a/../b"` → `false` (parent-dir segment in the middle)
- Invalid: `"a/./b"` → `false` (current-dir segment, per the function's explicit rejection of `"."` — confirm this is intentional by re-reading the function: yes, line 866 rejects `.` and `..` identically)
- Invalid: `"a//b"` → `false` (empty segment from a double slash, since `splitScalar` on `"a//b"` yields `["a", "", "b"]` and the loop rejects zero-length parts)
- Invalid: `"a/"` → `false` (trailing slash produces a trailing empty segment)

Since `isSafeRelativePath` is private, call it directly by name from within the test block (no import needed beyond what the file already has).

**Verify**: `zig build test 2>&1 | grep -i "isSafeRelativePath"` → no `error:` lines; overall `zig build test` → 0 failed.

### Step 2: Add a test for `shouldReplaceRef`

Cover: empty `replace_refs` slice → `false`; a matching `{origin, session_id}` pair present → `true`; a slice with one non-matching and one matching entry → `true`; a slice where origin matches but session_id doesn't (or vice versa) → `false`.

**Verify**: `zig build test` → 0 failed.

### Step 3: Add a test for `computeBundleId`

First locate `SelectedRef`'s definition in this file to get exact field names and types. Write a test that:
1. Calls `computeBundleId` twice with the same inputs (same `selected` slice contents and same `created_at_ms`) and asserts the two resulting hex strings are equal (determinism).
2. Calls it again with a different `created_at_ms` (or a different `selected` entry) and asserts the result differs from the first call (sensitivity to input — guards against a future regression that ignores an input field).

**Verify**: `zig build test` → 0 failed.

### Step 4: Confirm no regressions and check the new test count

**Verify**: `zig build check` → exit 0. `zig build test 2>&1 | tail -5` → shows a higher total test count than the baseline (276, per the count at the time this plan was written) reflecting the new tests, with 0 failed.

## Test plan

- This plan's content *is* the test plan — see Steps 1–3 for exact cases. No e2e changes.
- Verification: `zig build test` → all pass including new tests; `zig build check` → exit 0.

## Done criteria

- [ ] `zig build check` exits 0
- [ ] `zig build test` exits 0 with more total tests than the pre-change baseline and 0 failed
- [ ] New tests cover at minimum: `isSafeRelativePath` (the 9 cases in Step 1), `shouldReplaceRef` (4 cases in Step 2), `computeBundleId` determinism+sensitivity (Step 3)
- [ ] `git status` shows only `src/store/bundle.zig` modified
- [ ] `plans/README.md` status row for 005 updated to DONE

## STOP conditions

Stop and report back (do not improvise) if:
- `isSafeRelativePath`'s actual behavior differs from the excerpt above for any of the listed cases (e.g., it doesn't actually reject `"a/./b"` the way the excerpt suggests) — trust your own test run's output over this plan's predictions; if a predicted result is wrong, fix the plan's expected value by re-reading the function rather than weakening the test to match incorrect behavior, unless the "incorrect" behavior turns out to be intentional (re-check call sites at lines 604/612/627 for context on intent first).
- `SelectedRef`'s fields don't match `path`/`head_hash` as assumed — find the real struct definition and adjust the test, but if constructing one requires non-trivial setup (e.g., it embeds a type that itself requires I/O to construct), stop and report rather than fabricating fake data that doesn't reflect real usage.

## Maintenance notes

- These are characterization tests for existing, working behavior, not new functionality — they exist to catch regressions, especially in `isSafeRelativePath` given its security role in import path validation.
- If `validateManifest`/`validatePrivacyReportPath`/`validateBundleObjects` are refactored later (e.g., consolidated into one validator), keep `isSafeRelativePath`'s unit tests intact — they test the guard function itself, independent of which validator calls it.

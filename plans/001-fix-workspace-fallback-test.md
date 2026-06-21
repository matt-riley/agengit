# Plan 001: Fix `openWorkspaceDir` fallback tests so `zig build test` passes again

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 3b45f66..HEAD -- src/hook/event.zig`
> If `src/hook/event.zig` changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `3b45f66`, 2026-06-21

## Why this matters

`zig build test` currently fails with 2 failing tests out of 276, which means `zig build check` (the project's documented default verification command, per `CLAUDE.md`) is currently broken on `main`. The root cause is not a logic bug in the production code — it's a test-environment assumption that no longer holds because this repository now dogfoods `agit` on itself: a real `.agit/` directory exists at the repository root (you can confirm with `ls -la .agit`). The two failing tests assert that `openWorkspaceDir` falls back to the process cwd when no `.agit/` ancestor exists above a temp directory — but `std.testing.tmpDir` creates its temp directories under `.zig-cache/tmp/<random>/`, which is nested *inside* this repository, which *does* have a `.agit/` ancestor at the repo root. So `findStoreRoot` walking up from the tmp dir succeeds, `used_fallback` ends up `false`, and the test's `try std.testing.expect(workspace.used_fallback)` fails. Fixing this restores a clean `zig build check` for every contributor and CI run.

## Current state

- `src/hook/event.zig` — defines `openWorkspaceDir` (the function under test, lines 45–64) and the two failing tests (lines 388–448).
- `src/hook/event.zig:45-64`:
  ```zig
  pub fn openWorkspaceDir(io: std.Io, workspace_cwd: []const u8) !WorkspaceDir {
      const payload_dir = std.Io.Dir.cwd().openDir(io, workspace_cwd, .{}) catch {
          return fallback(io, .open_failed);
      };
      // Proactive safety: ensure the payload cwd leads to a real workspace.
      // If no .agit/ ancestor exists, downstream Recorder.open would fail.
      // Fall back to process cwd instead (fail-open per ADR 003).
      var root_dir = recorder_mod.findStoreRoot(io, payload_dir) catch |err| {
          payload_dir.close(io);
          return fallback(io, switch (err) {
              error.StoreNotFound => .no_store_ancestor,
              else => .open_failed,
          });
      };
      root_dir.close(io);
      // findStoreRoot succeeded (has .agit/ ancestor) — keep the opened dir.
      // Note: we do NOT check whether the .agit/ is in the SAME workspace as
      // the process cwd; the payload is authoritative per ADR 024.
      return .{ .dir = payload_dir, .used_fallback = false };
  }
  ```
- `src/hook/event.zig:388-421` — `test "openWorkspaceDir relative path outside workspace"`: creates a `std.testing.tmpDir`, makes a `subdir` inside it (no `.agit/`), `chdir`s into the tmp dir, calls `openWorkspaceDir(io, "subdir")`, and asserts `workspace.used_fallback` is `true`. **This fails** because the tmp dir lives under this repo's `.zig-cache/tmp/`, and `.agit/` exists at the repo root — an ancestor of `.zig-cache/tmp/`.
- `src/hook/event.zig:423-448` — `test "openWorkspaceDir absolute path outside workspace"`: same tmp-dir pattern, no chdir, calls `openWorkspaceDir(io, abs_path)` with the tmp dir's absolute path, asserts fallback. **Fails for the same reason.**
- Two other tests in the same file (`"openWorkspaceDir relative path to workspace"` around line ~355 and `"openWorkspaceDir absolute path to workspace"` at line 373) explicitly create a `.agit` dir inside the tmp dir with `try tmp.dir.createDirPath(io, ".agit")` and assert `!workspace.used_fallback` — these pass today, and must keep passing.
- The fix must make the "outside workspace" tests independent of the ambient filesystem, not just work around today's specific dogfooding setup (which could change again, e.g. if `.agit/` is later removed from the repo root for a different reason).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Run unit tests | `zig build test` | `Build Summary` shows all tests passing, no `error:` lines |
| Full check | `zig build check` | exit 0 |
| Format | `zig build fmt` | exit 0 (run before final verification) |
| Format check | `zig build check-fmt` | exit 0 |

## Scope

**In scope** (the only file you should modify):
- `src/hook/event.zig` (test code only — the two failing `test "..."` blocks; do not change `openWorkspaceDir` or `fallback` themselves, they are correct)

**Out of scope** (do NOT touch, even though related):
- `src/recorder.zig`'s `findStoreRoot` — it is working as designed (ADR 003, ADR 024); the bug is in the test's environment assumption, not in this function.
- The two passing "to workspace" tests (lines ~355–386) — leave them as-is.
- `.agit/` at the repo root — this is the project's own real dogfood store. Do not delete, move, or modify it.

## Git workflow

- Branch: `advisor/001-fix-workspace-fallback-test`
- Commit message style (conventional commits, per `CLAUDE.md`): `fix: isolate openWorkspaceDir fallback tests from repo's own .agit ancestor`
- Do NOT push or open a PR unless explicitly instructed.

## Steps

### Step 1: Root the "outside workspace" tests under an OS tmp dir instead of `.zig-cache/tmp`

`std.testing.tmpDir` creates directories under `.zig-cache/tmp/<random>/`, which is nested inside this repository. Because this repo has a real `.agit/` at its root (dogfooding), `findStoreRoot` walking up from any `.zig-cache/tmp/...` path will find it — so "outside workspace" can never actually be true for a `std.testing.tmpDir`-rooted path in this repo. The fix is to root these two tests' temp directories outside the repo entirely, under the OS temp directory, where no `.agit/` ancestor can exist.

In both `test "openWorkspaceDir relative path outside workspace"` (line 388) and `test "openWorkspaceDir absolute path outside workspace"` (line 423):

1. Replace `var tmp = std.testing.tmpDir(.{});` / `defer tmp.cleanup();` with a directory created under the OS temp dir. Read the temp root via `std.process.getEnvVarOwned(std.testing.allocator, "TMPDIR")` (falling back to `/tmp` if unset or empty, matching standard Unix convention — macOS sets `TMPDIR`, Linux typically doesn't), append a unique subdirectory name (e.g. derived from `std.testing.allocator`-obtained random bytes or a fixed-but-unlikely-to-collide name plus a counter — keep it simple, e.g. `"agit-event-test-outside-1"` and `"-2"` for the two tests, since they don't run concurrently with each other), create it with `std.Io.Dir.cwd().makePath(io, <path>)`, and open it.
2. Add a `defer` that recursively removes this directory (`std.Io.Dir.cwd().deleteTree(io, <path>)` or equivalent already-used helper in this codebase — check `src/util/fs.zig` for an existing recursive-delete helper before writing a new one).
3. Keep every other line in both tests unchanged: the `subdir` creation, `realPath` calls, `chdir` logic (for the relative-path test), and the final `openWorkspaceDir` call plus assertions all stay as they are — only the *source* of the temp directory changes from `std.testing.tmpDir` to the OS-tmp-rooted directory.
4. The two tests that already pass (`"openWorkspaceDir relative path to workspace"` and `"openWorkspaceDir absolute path to workspace"`, lines ~340–386) explicitly `createDirPath(io, ".agit")` inside their own tmp dir, so they are unaffected by ancestor lookups and should NOT be changed — leave them using `std.testing.tmpDir`.

**Verify**: `zig build test` → `Build Summary` line shows `0 failed`.

### Step 2: Confirm the two passing "to workspace" tests still pass

These tests (around lines 355–386) explicitly create their own `.agit` dir inside the tmp dir and don't depend on ancestor lookups beyond that, so they should be unaffected by your change. Confirm by name.

**Verify**: `zig build test 2>&1 | grep -i "openWorkspaceDir"` → no `error:` lines mentioning these two test names.

### Step 3: Run the full check suite

**Verify**: `zig build check` → exit code 0.

## Test plan

- No new test files — this plan only repairs two existing tests in `src/hook/event.zig` so they test the intended behavior (fallback when truly outside any workspace) regardless of where the test runner's tmp directory happens to live.
- Verification: `zig build test` → all pass. `zig build check` → exit 0.

## Done criteria

- [ ] `zig build test` exits 0 with 0 failed tests
- [ ] `zig build check` exits 0
- [ ] `git status` shows only `src/hook/event.zig` modified
- [ ] `plans/README.md` status row for 001 updated to DONE

## STOP conditions

Stop and report back (do not improvise) if:
- `src/hook/event.zig`'s `openWorkspaceDir` or `fallback` functions look different from the "Current state" excerpt above (the bug may have already been fixed differently, or the function signature changed).
- After moving the tmp dir source to `/tmp`/`$TMPDIR`, the tests still fail with `used_fallback == false` — this would mean `/tmp` itself has an `.agit/` ancestor on the executor's machine, which is a different, more unusual environment problem; report it rather than chasing it further.
- Fixing this requires changing `findStoreRoot`'s signature or behavior — that function is shared production code (ADR 003/024) and is out of scope for this plan.

## Maintenance notes

- Any future test that creates a `std.testing.tmpDir` and asserts "no ancestor `.agit/` exists" should use an OS-tmp-rooted directory, not the default `.zig-cache/tmp`-nested one, precisely because this repo dogfoods itself.
- If this repo ever stops dogfooding itself (i.e., the `.agit/` directory at the repo root is removed), these tests would have silently started passing again even without this fix — that's a reminder the original bug was environmental, not logical, and underscores why the fix should not depend on `.agit/`'s absence at the repo root.

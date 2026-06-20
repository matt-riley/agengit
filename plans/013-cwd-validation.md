# Plan 013: Reject absolute paths in hook payload workspace cwd

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b2d0213..HEAD -- src/hook.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `b2d0213`, 2026-06-20

## Why this matters

`openResolvedWorkspaceDir` in `hook.zig` resolves the `workspace_cwd` field
from a hook payload via `std.fs.path.resolve(gpa, &.{ ".", workspace_cwd })`.
If `workspace_cwd` is absolute (e.g., `/tmp/malicious-repo`), the resolution
produces that absolute path, and `agit` opens an arbitrary external directory,
recording activity into its `.agit/` store. Because hooks are fail-open, a
poisoned payload silently writes data to an unintended repository. Rejecting
absolute paths keeps recording confined to the directory tree the hook process
was started in.

## Current state

- `src/hook.zig:158-163` — `openResolvedWorkspaceDir`:
  ```zig
  fn openResolvedWorkspaceDir(
      io: std.Io,
      gpa: std.mem.Allocator,
      workspace_cwd: []const u8,
  ) ?std.Io.Dir {
      const resolved = std.fs.path.resolve(gpa, &.{ ".", workspace_cwd }) catch return null;
      defer gpa.free(resolved);
      return std.Io.Dir.cwd().openDir(io, resolved, .{}) catch null;
  }
  ```

- The existing test at `src/hook.zig:454-480` exercises `openResolvedWorkspaceDir`
  with a path like `/tmp/xxx/sub/..` (absolute with parent segments). This
  test currently passes an absolute path to verify that `..` components are
  normalized away. With the fix, any absolute `workspace_cwd` must be rejected,
  so this test must be updated to use a relative path instead.

- `src/hook.zig:480-488` — test for invalid cwd already exists:
  ```zig
  test "openResolvedWorkspaceDir returns null for invalid cwd" {
      const io = std.testing.io;
      const gpa = std.testing.allocator;
      try std.testing.expect(openResolvedWorkspaceDir(io, gpa, "\x00bad") == null);
  }
  ```
  Add a new test alongside it for the absolute-path rejection.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format | `zig build fmt` | exit 0 |
| Unit tests | `zig build test` | all pass, including updated/added hook.zig tests |
| Check | `zig build check` | exit 0 |

## Scope

**In scope**:
- `src/hook.zig` — modify `openResolvedWorkspaceDir` and update/add tests

**Out of scope**:
- `src/hook/runner.zig` — caller that invokes `openResolvedWorkspaceDir`; no change needed
- `src/recorder.zig` — downstream handling; unchanged
- Any other CLI files

## Git workflow

- Branch: `advisor/013-cwd-validation`
- Commit style: `fix: reject absolute cwd in hook payload`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reject absolute paths in `openResolvedWorkspaceDir`

In `src/hook.zig`, change `openResolvedWorkspaceDir` to check for absolute
paths before resolving. Use `std.fs.path.isAbsolute` which is available in
Zig 0.16.0.

The new body:
```zig
fn openResolvedWorkspaceDir(
    io: std.Io,
    gpa: std.mem.Allocator,
    workspace_cwd: []const u8,
) ?std.Io.Dir {
    if (std.fs.path.isAbsolute(workspace_cwd)) return null;
    const resolved = std.fs.path.resolve(gpa, &.{ ".", workspace_cwd }) catch return null;
    defer gpa.free(resolved);
    return std.Io.Dir.cwd().openDir(io, resolved, .{}) catch null;
}
```

**Verify**: `zig build test` → all existing tests pass (the affected test will
fail until Step 2, which is expected).

### Step 2: Update the existing test to use relative paths

The test at `src/hook.zig:454-480` currently constructs an absolute path
`/tmp/xxx/sub/..` and verifies normalization to `/tmp/xxx`. Change this test
to create a subdirectory under the temp dir and use a relative path with
parent segments.

Before (approximately lines 454-480):
```zig
test "openResolvedWorkspaceDir normalizes parent segments" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub");

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const workspace_cwd = try std.fmt.allocPrint(gpa, "{s}/sub/..", .{tmp_path});
    defer gpa.free(workspace_cwd);

    const dir_opt = openResolvedWorkspaceDir(io, gpa, workspace_cwd);
    try std.testing.expect(dir_opt != null);
    var dir = dir_opt.?;
    defer dir.close(io);

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try dir.realPath(io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_len];
    try std.testing.expectEqualStrings(tmp_path, dir_path);
}
```

After (relative path version):
```zig
test "openResolvedWorkspaceDir normalizes parent segments" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "sub");

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const workspace_cwd = "sub/..";
    const dir_opt = openResolvedWorkspaceDir(io, gpa, workspace_cwd);
    try std.testing.expect(dir_opt != null);
    var dir = dir_opt.?;
    defer dir.close(io);

    var dir_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try dir.realPath(io, &dir_path_buf);
    const dir_path = dir_path_buf[0..dir_len];
    try std.testing.expectEqualStrings(tmp_path, dir_path);
}
```

**Verify**: `zig build test` → all hook.zig tests pass.

### Step 3: Add a test for absolute-path rejection

Append this test after the existing test at `src/hook.zig:480-488`:

```zig
test "openResolvedWorkspaceDir rejects absolute paths" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_len = try tmp.dir.realPath(io, &tmp_path_buf);
    const tmp_path = tmp_path_buf[0..tmp_len];

    const workspace_cwd = try std.fmt.allocPrint(gpa, "{s}/dummy", .{tmp_path});
    defer gpa.free(workspace_cwd);

    try std.testing.expect(openResolvedWorkspaceDir(io, gpa, workspace_cwd) == null);
}
```

**Verify**: `zig build test` → all hook.zig tests pass.

## Test plan

- One existing test updated (absolute → relative path)
- One new test added (absolute path rejection)
- Pattern to follow: `src/hook.zig:454-488`.
- Verification: `zig build test` → all hook.zig tests pass.

## Done criteria

- [ ] `zig build fmt` exits 0
- [ ] `zig build test` exits 0; all hook.zig tests pass
- [ ] `zig build check` exits 0
- [ ] Only `src/hook.zig` was modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `openResolvedWorkspaceDir` has a different signature or body than the excerpt.
- `std.fs.path.isAbsolute` does not exist in Zig 0.16.0 (check with `grep "isAbsolute" $(zig env | grep lib_dir | cut -d'"' -f4)/std/fs/path.zig`).
- The existing `openResolvedWorkspaceDir normalizes parent segments` test was
  already removed or renamed.

## Maintenance notes

- This change is narrow but security-critical. Any future relaxation of the
  absolute-path check requires a security review.
- The caller (`src/hook/runner.zig`) receives `null` and reports a hook failure
  with context "invalid_workspace_cwd" — this is the expected path. No caller
  changes are needed because `null` is already handled.
- If a legitimate hook client needs absolute cwd support, it should be added
  behind an allow-list, not by removing this check.

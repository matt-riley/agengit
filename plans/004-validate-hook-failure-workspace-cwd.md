# Plan 004: Validate/normalize the hook failure workspace path

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat bae6a6c..HEAD -- src/hook.zig`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `bae6a6c`, 2026-06-20

## Why this matters

`hook.reportFailure()` uses the agent payload's `cwd` field to decide where to write the durable `log/hook-error.log` entry. The value is passed straight into `openDir`. That path can be relative and contain `..` segments, so it could resolve outside the intended repository. Since hooks run as the user the risk is contained, but the repo already has `validateWorkspaceRelativePath()` for snapshot paths; the hook failure path deserves the same defensive normalization.

## Current state

- `src/hook.zig:177-294` — `reportFailure()` branches on `ctx.workspace_cwd`:

```zig
    if (ctx.workspace_cwd) |workspace_cwd| {
        const dir = std.Io.Dir.cwd().openDir(io, workspace_cwd, .{}) catch {
            recorder_mod.logHookFailureFromCwd(...);
            return;
        };
        defer dir.close(io);
        recorder_mod.logHookFailureFromDir(io, gpa, dir, ...);
        return;
    }
```

There is no normalization or validation of `workspace_cwd` before it is opened.

- `src/store/path_safety.zig` validates workspace-relative snapshot paths but is not used here.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Typecheck / test | `zig build test` | exit 0, all tests pass |
| Format | `zig build fmt` | exit 0 |

## Scope

**In scope**:
- `src/hook.zig`
- Tests inside `src/hook.zig`

**Out of scope**:
- `src/store/path_safety.zig` (do not change; it is only referenced as a convention example).
- Hook payload parsing or agent adapters.

## Steps

### Step 1: Add a workspace-directory helper

In `src/hook.zig`, add a private helper that resolves a relative payload `cwd` against the process's actual current working directory before opening it. Keep the function fail-open: on any error it returns `null` so the caller falls back to `logHookFailureFromCwd`.

Target shape:

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

### Step 2: Use the helper in `reportFailure`

Replace the direct `std.Io.Dir.cwd().openDir(io, workspace_cwd, .{})` call in `reportFailure()` with `openResolvedWorkspaceDir(io, gpa, workspace_cwd)`.

Target shape:

```zig
    if (ctx.workspace_cwd) |workspace_cwd| {
        const dir = openResolvedWorkspaceDir(io, gpa, workspace_cwd) orelse {
            recorder_mod.logHookFailureFromCwd(io, gpa, ctx.agent, ctx.err, .{ ... });
            return;
        };
        defer dir.close(io);
        recorder_mod.logHookFailureFromDir(io, gpa, dir, ...);
        return;
    }
```

**Verify**: `zig build test` still passes.

### Step 3: Add a regression test

Add a test inside `src/hook.zig` that verifies normalization:

1. Create a temp directory with a subdirectory `sub`.
2. Call `openResolvedWorkspaceDir` (or exercise `reportFailure`) with `workspace_cwd = "../sub"` relative to the current process cwd, and confirm the opened directory resolves correctly (e.g., its real path contains `sub`).
3. Confirm that a path containing a null byte or backslash returns `null`/falls back safely.

If `openResolvedWorkspaceDir` is private, tests in the same file can call it directly.

**Verify**: `zig build test` shows the new test passing.

## Test plan

- `test "reportFailure resolves relative payload cwd"` — `..` segments are normalized and the intended directory is opened.
- `test "reportFailure rejects invalid payload cwd"` — null byte / backslash cause fallback rather than opening an arbitrary path.

Model the tests on the existing `src/hook.zig` tests (e.g., `test "redactSnippetAlloc masks sensitive values"`).

## Done criteria

- [ ] `reportFailure()` no longer opens `ctx.workspace_cwd` directly.
- [ ] A normalization helper resolves relative paths against the process cwd.
- [ ] Invalid/unopenable paths fall back to the existing `logHookFailureFromCwd` path.
- [ ] New regression tests pass.
- [ ] `zig build test` exits 0.
- [ ] `zig build check-fmt` exits 0.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- `std.fs.path.resolve` is unavailable in this Zig version or behaves differently.
- The helper allocates in a way that leaks in the existing `reportFailure()` error paths.

## Maintenance notes

This is a hardening change. If the project later wants stricter rules (e.g., restrict `workspace_cwd` to inside a discovered `.agit/` root), extend this helper rather than changing `reportFailure()` again.

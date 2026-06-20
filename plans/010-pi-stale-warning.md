# Plan 010: Auto-detect stale pi extension binary path on init

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 07fffa1..HEAD -- src/cli/pi_extension.zig src/cli/init.zig tests/e2e/init/fresh.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: robustness
- **Planned at**: commit `07fffa1`, 2026-06-20

## Why this matters

The pi extension (`~/.pi/agent/extensions/agit-recorder.js`) embeds the absolute
path to the agit binary at install time. If agit is later moved or upgraded
(e.g., `brew upgrade`, manual reinstall to a different path), the pi extension
silently fails — all hook events are swallowed by the fail-open `try/catch`
wrapper, and pi records nothing. The `agit doctor` command detects this
(`agent_binary_mismatch`), but the user has to run it manually. Adding a
warning at `agit init` time when an existing extension points to a different
binary path would give users immediate feedback.

## Current state

- `src/cli/pi_extension.zig:render()` embeds the absolute binary path.
- `src/cli/init.zig:installJsExtension()` always overwrites the extension file
  without checking what's currently there (lines ~262-280).
- `src/cli/doctor.zig:835+` checks for binary mismatch but only when the user
  runs `agit doctor`.

The init flow currently:
1. Checks if the pi binary is on PATH
2. Creates the directory `~/.pi/agent/extensions/`
3. Writes the generated extension (overwriting any existing file)
4. Reports success

There's no check of the existing extension file before overwriting it.

## Commands you will need

| Purpose   | Command                  | Expected on success |
|-----------|--------------------------|---------------------|
| Format    | `zig build fmt`          | exit 0              |
| Unit test | `zig build test`         | all pass            |
| E2E test  | `zig build test-e2e`     | all pass            |
| Full check| `zig build check`        | exit 0              |

## Scope

**In scope** (the only files you should modify):
- `src/cli/init.zig` — add a pre-overwrite check in `installJsExtension`
- `tests/e2e/init/fresh.zig` — optionally add an assertion that fresh init
  doesn't warn about path mismatch

**Out of scope** (do NOT touch):
- `src/cli/pi_extension.zig` — the render logic is fine as-is
- `src/cli/doctor.zig` — the doctor check is already correct
- The extension template itself
- Any other `.zig` files

## Git workflow

- Branch: `advisor/010-pi-stale-warning`
- Commit style: `feat: warn when pi extension binary path differs on init`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a stale-detection helper to `installJsExtension`

In `src/cli/init.zig`, find the `installJsExtension` function (around line
262). Before the existing write logic, add a check:

```zig
fn installJsExtension(
    io: std.Io,
    gpa: std.mem.Allocator,
    agent_plan: init_plan_mod.AgentPlan,
    exe: []const u8,
    crash_after_tmp_write: bool,
    stdout: *std.Io.File.Writer,
) !void {
    const config_path = agent_plan.config_path;
    const agent_name = agent_plan.agent.name;

    // NEW: Check for an existing extension with a stale binary path.
    const existing = std.Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .unlimited) catch null;
    if (existing) |text| {
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, pi_extension.js_extension_marker) != null and
            std.mem.indexOf(u8, text, exe) == null)
        {
            try stdout.interface.print(
                "agit init: existing {s} extension points to a different agit binary; it will be overwritten.\n",
                .{agent_name},
            );
        }
    }

    // ... existing write logic (arena, render, createFileAtomic, etc.)
```

**Verify**: `zig build test` → all pass. The unit tests in `init.zig` must still
pass.

### Step 2: Handle the "file does not exist yet" case

The `readFileAlloc` returns `error.FileNotFound` for a fresh install. The
`catch null` pattern already handles this — no message needed for first-time
install.

**Verify**: Run `zig build test` → all tests pass. The `init/fresh` e2e test
must NOT show the warning (because it's a fresh install with no prior
extension).

### Step 3: Add a test for the stale-path warning

Add a unit test to `src/cli/init.zig` that verifies the warning is printed
when an existing extension has a different binary path. The test pattern
follows existing tests in `init.zig`:

```zig
test "installJsExtension warns on stale binary path" {
    // Create a sandbox home directory with a pre-existing pi extension
    // that embeds a different binary path. Run init --agent pi and assert
    // the stdout contains the warning.
}
```

Alternatively, add an assertion to the existing e2e test `tests/e2e/init/fresh.zig`
to verify the warning does NOT appear on a fresh init (it shouldn't).

**Verify**: `zig build test` → all pass. `zig build test-e2e` → all pass.

### Step 4: Run full verification

**Verify**: `zig build check` → exit 0; `zig build test-e2e` → all pass.

## Test plan

- Existing unit tests cover the init flow. No breaking changes.
- New unit test: verify the warning is emitted when an existing extension has a
  stale binary path.
- E2E test: the existing `init/fresh` test verifies the pi extension is created
  — ensure the stale warning does NOT appear for fresh installs.
- Verify with: `zig build test` → all pass; `zig build test-e2e` → all pass.

## Done criteria

- [ ] `zig build check` exits 0
- [ ] `zig build test` exits 0; all tests pass
- [ ] `zig build test-e2e` exits 0
- [ ] `agit init --agent pi` on a fresh install produces no stale-path warning
- [ ] `agit init --agent pi` on an existing extension with a different binary
  path prints the warning before overwriting
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the locations in "Current state" doesn't match the excerpts.
- The e2e `init/fresh` test fails — this test was recently updated to include pi
  coverage (plan 008); if it fails, the existing test may have issues unrelated
  to this change.
- The `readFileAlloc` on the extension path returns errors other than
  `FileNotFound` for reasons that aren't clear.

## Maintenance notes

- The stale-path check uses `pi_extension.js_extension_marker` (imported from
  `src/cli/pi_extension.zig`). If plan 009 (de-duplicate marker) is done first,
  use the imported constant. If not, use the literal string and add a
  `// Keep in sync with pi_extension.zig` comment.
- The warning is informational only — it does not block the init. This matches
  the fail-open philosophy.
- Future enhancements could prompt for confirmation or offer to run `agit
  doctor` afterward.

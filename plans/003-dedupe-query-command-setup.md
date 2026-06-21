# Plan 003: Extract shared store-open/config-load/redaction setup from query commands

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 3b45f66..HEAD -- src/cli/timeline.zig src/cli/watch.zig src/cli/recall.zig src/cli/grep.zig src/cli/shared.zig`
> If any of these files changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `3b45f66`, 2026-06-21

## Why this matters

`src/cli/timeline.zig`, `src/cli/watch.zig`, `src/cli/recall.zig`, and `src/cli/grep.zig` each contain a near-identical ~12-line block: open the store, load `.agit/config.json` (with identical error-diagnostic handling on failure), and compute whether redaction should be applied. The blocks are copy-pasted, not shared — confirmed by `grep -n "loadOrDefaultFromStore\|shouldUseRedaction" src/cli/*.zig`, which shows the same sequence repeated verbatim across all four files. Any future change to this setup (e.g., a new config field that affects redaction, or a different error code for config load failures) requires editing four files in lockstep, and it's easy to update three and miss the fourth. Extracting this into one shared helper in `src/cli/shared.zig` (which already holds `resolveSessionFilter` and other cross-command helpers) removes the duplication and makes future changes a one-file edit.

## Current state

- `src/cli/shared.zig` — already the home for cross-command CLI helpers. Currently exports `RedactionMode`, `SessionFilter`, `shouldUseRedaction`, `resolveSessionFilter`, `buildMatchQuery`, `appendQuotedToken`. This is where the new helper goes.
- `src/cli/shared.zig:1-21` (imports and existing redaction helper, to match style):
  ```zig
  const std = @import("std");
  const output_mod = @import("output.zig");
  const status = @import("status.zig");

  pub const RedactionMode = enum {
      auto,
      redacted,
      full,
  };

  pub const SessionFilter = struct {
      origin: ?[]const u8 = null,
      session_id: ?[]const u8 = null,
  };

  pub fn shouldUseRedaction(mode: RedactionMode, redacted_by_default: bool) bool {
      return switch (mode) {
          .auto => redacted_by_default,
          .redacted => true,
          .full => false,
      };
  }
  ```
- The duplicated block, as it appears identically in `src/cli/timeline.zig`, `src/cli/recall.zig`, and `src/cli/grep.zig` (and with one extra `pragma busy_timeout` line in `src/cli/watch.zig` — see below):
  ```zig
  var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
  defer store.deinit(io);

  var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
      try status.writeDiagnostic(&stdout, options.format, usage.name, .{
          .code = "invalid_config",
          .message = "Failed to load .agit/config.json.",
          .hint = @errorName(err),
          .path = ".agit/config.json",
      });
      try stdout.flush();
      std.process.exit(1);
  };
  defer loaded_config.deinit();
  const use_redaction = shared.shouldUseRedaction(options.redaction_mode, loaded_config.value.privacy.display.redacted_by_default);
  ```
  Confirmed at: `src/cli/timeline.zig:42-56`, `src/cli/recall.zig:82-96`, `src/cli/grep.zig:71-85` (line numbers approximate — match by content, not exact line number, since prior edits in this codebase may have shifted them slightly).
- `src/cli/watch.zig:54-69` has the same block but with one extra line right after opening the store:
  ```zig
  var store = try status.openStoreOrExit(io, gpa, &stdout, options.format, usage.name);
  defer store.deinit(io);
  try store.index.db.execNoArgs("pragma busy_timeout = 250");

  var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
      ...
  };
  ```
  This extra line is `watch`-specific (it sets a busy-timeout because `watch` polls the index repeatedly while other processes may be writing). **Preserve this line in `watch.zig`** — either by keeping it as a separate statement right after calling the new shared helper, or by adding an optional parameter to the helper. Prefer keeping it as a separate statement immediately after the helper call in `watch.zig` only — simpler, and keeps the shared helper free of a `watch`-only concern.
- All four files already import `config_mod` (`@import("../store/config.zig")`), `status` (`@import("status.zig")`), and `shared` (`@import("shared.zig")`) — confirm this for each file before editing; if any file is missing one of these imports today, that's unexpected and should be treated as a drift signal (STOP condition).
- Each of the four commands has its own `Options` struct with at least `format: output_mod.Format` and `redaction_mode: shared.RedactionMode` fields — the new helper needs both of these as parameters since it can't assume a shared `Options` type across files.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Unit tests | `zig build test` | 0 failed |
| E2E tests | `zig build test-e2e` | all pass |
| Full check | `zig build check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/cli/shared.zig` (add the new helper)
- `src/cli/timeline.zig`
- `src/cli/watch.zig`
- `src/cli/recall.zig`
- `src/cli/grep.zig`

**Out of scope** (do NOT touch, even though related):
- `src/cli/stats.zig`, `src/cli/eval.zig`, `src/cli/log.zig`, `src/cli/between.zig` — these call `status.openStoreOrExit` but do **not** load config or compute redaction (confirmed via `grep -n "loadOrDefaultFromStore" src/cli/*.zig` — they're absent from this list). Do not force them onto the new helper; they have a different, smaller setup need.
- `src/cli/shared.zig`'s existing functions (`resolveSessionFilter`, `buildMatchQuery`, etc.) — leave unchanged, only add the new function.
- Any command's flag parsing, output formatting, or business logic beyond the setup block itself.

## Git workflow

- Branch: `advisor/003-dedupe-query-command-setup`
- Commit message: `refactor: extract shared store/config/redaction setup for query commands`
- Do NOT push or open a PR unless explicitly instructed.

## Steps

### Step 1: Add the shared helper to `src/cli/shared.zig`

Add a new struct and function. The struct holds the three things every caller needs out of the setup block; the function performs the setup and returns it (or exits the process on config-load failure, matching today's behavior exactly — do not change error handling to be recoverable, since none of the four callers currently handle a config-load failure as a recoverable error).

```zig
pub const QuerySetup = struct {
    config: std.json.Parsed(config_mod.Config), // match the exact type loadOrDefaultFromStore returns — verify by checking its return type in src/store/config.zig before writing this
    use_redaction: bool,

    pub fn deinit(self: *QuerySetup) void {
        self.config.deinit();
    }
};

pub fn loadQuerySetup(
    io: std.Io,
    gpa: std.mem.Allocator,
    store: *const store_mod.Store, // match whatever type store.root actually needs; check the existing callers' `store.root` usage and openStoreOrExit's return type first
    stdout: *std.Io.File.Writer,
    format: output_mod.Format,
    command_name: []const u8,
    redaction_mode: RedactionMode,
) QuerySetup {
    var loaded_config = config_mod.loadOrDefaultFromStore(io, store.root, gpa) catch |err| {
        status.writeDiagnostic(stdout, format, command_name, .{
            .code = "invalid_config",
            .message = "Failed to load .agit/config.json.",
            .hint = @errorName(err),
            .path = ".agit/config.json",
        }) catch {};
        stdout.flush() catch {};
        std.process.exit(1);
    };
    const use_redaction = shouldUseRedaction(redaction_mode, loaded_config.value.privacy.display.redacted_by_default);
    return .{ .config = loaded_config, .use_redaction = use_redaction };
}
```

Before finalizing this signature: read `src/store/config.zig` to get `loadOrDefaultFromStore`'s exact return type (it may not be `std.json.Parsed(Config)` — match whatever it actually is), and read `src/cli/status.zig` for `openStoreOrExit`'s return type to get the exact `store` parameter type right (it's likely `store_mod.Store`, possibly returned by value rather than needing a pointer — match the existing call sites' usage, e.g. `var store = try status.openStoreOrExit(...)`, then `store.root` is accessed directly, not `store.*.root`). Add `const config_mod = @import("../store/config.zig");` and `const store_mod = @import("../store/store.zig");` to `shared.zig`'s imports if not already present.

You will also need to handle the `try`/error propagation correctly: `status.writeDiagnostic` and `stdout.flush()` return errors in the original code (`try status.writeDiagnostic(...)`, `try stdout.flush()`), but since `std.process.exit(1)` never returns, the function after it is `noreturn` on that branch — match the original code's exact error-handling style (it does NOT swallow these with `catch {}` in the original; it propagates with `try` up to the point of `std.process.exit`). Adjust the snippet above to use `try` and make `loadQuerySetup` return `!QuerySetup` instead of `QuerySetup`, propagating errors from `writeDiagnostic`/`flush` to the caller exactly as today, since exit(1) is unconditional after those anyway. Match this exactly against one real call site (e.g. `timeline.zig`'s block) before writing the final version.

**Verify**: `zig build` → exit 0 (compiles, even though nothing calls it yet).

### Step 2: Wire `timeline.zig`, `recall.zig`, and `grep.zig` to use the new helper

In each of these three files, replace the duplicated block (store open is unaffected and stays; only the config-load + redaction computation lines change) with a call to `shared.loadQuerySetup(...)`, passing that file's own `options.format`, `usage.name`, and `options.redaction_mode`. Replace subsequent uses of `loaded_config.value...` and `use_redaction` with the new struct's fields (e.g. `setup.config.value...`, `setup.use_redaction`), and add `defer setup.deinit();` in place of the old `defer loaded_config.deinit();`.

Do this one file at a time, building after each:

**Verify** (after each file): `zig build` → exit 0.

### Step 3: Wire `watch.zig`, preserving its `pragma busy_timeout` line

Same as Step 2, but keep `try store.index.db.execNoArgs("pragma busy_timeout = 250");` as its own statement, placed right after `store.deinit(io)`'s `defer` and before the call to `shared.loadQuerySetup(...)`.

**Verify**: `zig build` → exit 0.

### Step 4: Run the full test suite

**Verify**: `zig build test` → 0 failed. `zig build test-e2e` → all pass (pay particular attention to any timeline/watch/recall/grep e2e tests that exercise config-load failure or redaction toggling — search `tests/e2e/` for `invalid_config` or `redact` to find them).

## Test plan

- No new tests needed — this is a behavior-preserving refactor. Existing e2e coverage (`tests/e2e/investigation/views.zig`, `tests/e2e/privacy/*.zig`, and any per-command tests under `tests/e2e/`) already exercises the config-load and redaction paths for these four commands; rely on those passing unchanged.
- Verification: `zig build test-e2e` → all pass, identical pass/fail set to before the change (run `zig build test-e2e` once before starting Step 1 and save the output to compare).

## Done criteria

- [ ] `zig build check` exits 0
- [ ] `zig build test-e2e` exits 0, same tests passing as the pre-change baseline
- [ ] `grep -n "loadOrDefaultFromStore" src/cli/timeline.zig src/cli/recall.zig src/cli/grep.zig src/cli/watch.zig` shows no direct calls remaining in these four files (the call now lives only in `shared.zig`)
- [ ] `git status` shows only the five in-scope files modified
- [ ] `plans/README.md` status row for 003 updated to DONE

## STOP conditions

Stop and report back (do not improvise) if:
- `loadOrDefaultFromStore`'s actual return type, or `openStoreOrExit`'s actual return type, differs meaningfully from what's assumed in Step 1's draft signature (e.g., it's not a `std.json.Parsed(...)`-shaped value) — adjust the helper signature to match reality, but if doing so would require changing every caller's surrounding code in non-mechanical ways, stop and report instead.
- Any of the four target files has diverged from the "Current state" excerpts (e.g., a fifth setup step has been added, or error handling has changed) — re-read the live file and decide whether the helper still fits; if not, stop and report.
- `watch.zig`'s `pragma busy_timeout` line turns out to depend on ordering relative to config load in a way that isn't obvious from the excerpt (e.g., a later line references `store.index.db` in a way affected by the pragma) — verify by reading the full `watch.zig` `run` function before assuming the line can be freely relocated.

## Maintenance notes

- Any new query command added in the future that needs store + config + redaction setup should call `shared.loadQuerySetup` from the start rather than copy-pasting the block again — point future contributors at this helper (e.g., mention it in a comment on the helper itself).
- `stats.zig`, `eval.zig`, `log.zig`, and `between.zig` were deliberately left out of this refactor because they don't need the config/redaction part. If a future change makes them need it too, extend them to call `shared.loadQuerySetup` rather than re-introducing the duplicated block.

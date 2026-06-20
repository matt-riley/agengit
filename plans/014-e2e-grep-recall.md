# Plan 014: Add e2e test coverage for grep and recall commands

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b2d0213..HEAD -- tests/e2e/ src/cli/grep.zig src/cli/recall.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `b2d0213`, 2026-06-20

## Why this matters

`agit grep` and `agit recall` are two of the four core "investigation"
commands (along with `eval` and `stats`). They have no end-to-end test
coverage. The e2e test suite (7 files, ~1,600 LOC) already exercises `init`,
`fsck`, `privacy scan`, and `eval`. Adding e2e coverage for `grep` and
`recall` ensures behavioral regressions in command-line parsing, query
execution, and JSON output formatting are caught during `zig build test-e2e`.

## Current state

- `tests/e2e/all.zig` — entry point that imports and runs all e2e modules.
- `tests/e2e/eval.zig` — most recently added e2e module (348 LOC). Provides a
  clear pattern: uses `harness.Sandbox`, creates `.agit/`, records turns via
  `recordCodexTurn`, then runs CLI commands and asserts JSON output.
- `tests/e2e/support/harness.zig` — `Sandbox` struct that creates a temp dir,
  a repo subdir, and runs the `agit` binary.
- `src/cli/grep.zig` — CLI entry point. Supports `--json`, `--origin`, `--session`,
  `--limit`, and a positional query.
- `src/cli/recall.zig` — CLI entry point. Supports `--json`, `--origin`, `--session`,
  `--query`, `--compact`, and various outcome filters.

### Pattern from `tests/e2e/eval.zig`

The e2e eval tests use a helper `recordCodexTurn` defined at the bottom of the
file. It writes a complete codex turn via the `agit observe` command:

```zig
fn recordCodexTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    user_prompt: []const u8,
    tool_name: []const u8,
    tool_args: []const u8,
    tool_result: []const u8,
    assistant_summary: []const u8,
) !void {
    ...
}
```

This is the recommended pattern — use `sandbox.run(&.{"observe", ...}, null)` to
record data, then exercise the target command against it.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| E2E tests | `zig build test-e2e` | all pass |
| Format | `zig build fmt` | exit 0 |
| Check | `zig build check` | exit 0 |

## Scope

**In scope**:
- `tests/e2e/grep.zig` — create with tests for grep in JSON and human modes
- `tests/e2e/recall.zig` — create with tests for recall in JSON and compact modes
- `tests/e2e/all.zig` — register the two new modules

**Out of scope**:
- `src/cli/grep.zig` and `src/cli/recall.zig` — read-only reference
- `tests/e2e/support/harness.zig` — read-only, no changes needed
- Other e2e files (init, fsck, privacy, eval)

## Git workflow

- Branch: `advisor/014-e2e-grep-recall`
- Commit style: `test: add e2e tests for grep and recall commands`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `tests/e2e/grep.zig`

Create a new file `tests/e2e/grep.zig` covering two tests: one that verifies
JSON output for a matching term, one that verifies a non-query returns an error.

```zig
const std = @import("std");
const harness = @import("support/harness.zig");

test "grep/json finds a term in recorded messages" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(
        &sandbox,
        "grep-session",
        "turn-1",
        "Search for the word banana",
        "bash",
        "echo banana",
        "banana output",
        "Found the banana.",
    );

    var result = try sandbox.run(&.{ "grep", "--json", "banana" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.stdout, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    const matches = data.array;
    try std.testing.expect(matches.items.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "banana") != null);
}

test "grep/json returns empty array for non-matching term" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(&sandbox, "grep-empty", "turn-1", "Nothing relevant.", "bash", "true", "", "Done.");

    var result = try sandbox.run(&.{ "grep", "--json", "nonexistent_term_12345" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.stdout, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    try std.testing.expectEqual(@as(usize, 0), data.array.items.len);
}

fn recordCodexTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    user_prompt: []const u8,
    tool_name: []const u8,
    tool_args: []const u8,
    tool_result: []const u8,
    assistant_summary: []const u8,
) !void {
    _ = session_id;
    _ = turn_id;
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"session_id\":\"{s}\",\"turn_id\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}},{{\"role\":\"assistant\",\"content\":\"{s}\"}}],\"tool_calls\":[{{\"tool_name\":\"{s}\",\"args\":\"{s}\",\"result\":\"{s}\"}}],\"cwd\":\".\"}}",
        .{ session_id, turn_id, user_prompt, assistant_summary, tool_name, tool_args, tool_result },
    );
    defer std.testing.allocator.free(payload);
    var result = try sandbox.run(&.{ "observe", "--stdin" }, payload);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}
```

**Verify**: `zig build test-e2e` → at minimum, the old tests still pass (the new
file isn't imported yet, so it won't be compiled).

### Step 2: Create `tests/e2e/recall.zig`

Create a new file `tests/e2e/recall.zig` covering JSON and compact output modes.

```zig
const std = @import("std");
const harness = @import("support/harness.zig");

test "recall/json returns steps for a session" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(&sandbox, "recall-session", "turn-1", "Hello world", "bash", "echo hi", "hi", "Done.");

    var result = try sandbox.run(&.{ "recall", "--json", "--session", "codex/recall-session" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, result.stdout, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const data = parsed.value.object.get("data") orelse return error.MissingData;
    try std.testing.expect(std.mem.eql(u8, data.object.get("envelope").?.string, "recall"));
}

test "recall/compact returns a short summary" {
    var sandbox = try harness.Sandbox.init(std.testing.allocator);
    defer sandbox.deinit();

    try sandbox.writeRepoFile(".agit/.keep", "");
    try recordCodexTurn(&sandbox, "recall-compact", "turn-1", "Compact test", "bash", "ls", "", "Done.");

    var result = try sandbox.run(&.{ "recall", "--compact", "--session", "codex/recall-compact" }, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(result.stdout.len > 0);
}

fn recordCodexTurn(
    sandbox: *harness.Sandbox,
    session_id: []const u8,
    turn_id: []const u8,
    user_prompt: []const u8,
    tool_name: []const u8,
    tool_args: []const u8,
    tool_result: []const u8,
    assistant_summary: []const u8,
) !void {
    const payload = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"session_id\":\"{s}\",\"turn_id\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}},{{\"role\":\"assistant\",\"content\":\"{s}\"}}],\"tool_calls\":[{{\"tool_name\":\"{s}\",\"args\":\"{s}\",\"result\":\"{s}\"}}],\"cwd\":\".\"}}",
        .{ session_id, turn_id, user_prompt, assistant_summary, tool_name, tool_args, tool_result },
    );
    defer std.testing.allocator.free(payload);
    var result = try sandbox.run(&.{ "observe", "--stdin" }, payload);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}
```

**Verify**: `zig build test-e2e` → old tests still pass.

### Step 3: Register the new modules in `tests/e2e/all.zig`

Read `tests/e2e/all.zig` and add imports for the two new files:

```zig
_ = @import("grep.zig");
_ = @import("recall.zig");
```

**Verify**: `zig build test-e2e` → all tests pass, including the 4 new ones.

## Test plan

- Each test creates a `harness.Sandbox`, writes `.agit/.keep`, records one
  turn via the `observe` command, then runs the target command.
- Pattern to follow: `tests/e2e/eval.zig`.
- The `recordCodexTurn` helper is duplicated in each e2e file — this is the
  existing convention (eval.zig also has its own copy).
- Verification: `zig build test-e2e` → passing count increases by 4.

## Done criteria

- [ ] `zig build fmt` exits 0
- [ ] `zig build test-e2e` exits 0; new grep/recall tests pass
- [ ] `zig build check` exits 0
- [ ] Exactly 3 files created/modified: `tests/e2e/grep.zig`, `tests/e2e/recall.zig`,
      `tests/e2e/all.zig`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `tests/e2e/all.zig` does not exist or has a different import format.
- `tests/e2e/support/harness.zig` does not have a `Sandbox.init` or `run` method.
- `observe --stdin` no longer accepts the payload format used in the test.
- The `grep` or `recall` JSON output envelope shape (`envelope`, `data`) has
  changed from what the tests assert.

## Maintenance notes

- These tests exercise the CLI → observe → grep/recall pipeline. If the
  `observe` command's payload format changes, all e2e tests (including eval)
  will need updates.
- The `recordCodexTurn` helper uses inline JSON formatting; if the payload
  schema changes, these tests will fail first. This is good — they act as
  schema-change detectors.
- Adding `--limit` or `--since` flag tests is deferred: the basic coverage
  validates the happy path; edge-case flag testing is lower priority.

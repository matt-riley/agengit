# Plan 012: Add unit tests for CLI investigation command helpers

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b2d0213..HEAD -- src/cli/grep.zig src/cli/recall.zig src/cli/eval.zig`
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

`src/cli/grep.zig` (313 LOC, 0 tests), `src/cli/recall.zig` (527 LOC, 0 tests),
and `src/cli/eval.zig` (681 LOC, 0 tests) are three of the four core
"investigation" CLI commands (along with `stats`). They have no unit tests
whatsoever. The `run` and `parseOptions` functions require a real store, but
many internal helpers are pure functions that operate on strings and data
structures. Testing these helpers catches regressions in query building,
output formatting, and option interpretation without needing a full store or
binary build.

## Current state

### `src/cli/grep.zig` — testable helpers

- `grep.zig:336` — `buildMatchQuery`:
  ```zig
  fn buildMatchQuery(gpa: std.mem.Allocator, query: []const u8) ![]u8 {
      var out: std.ArrayList(u8) = .empty;
      errdefer out.deinit(gpa);
      var tokens = std.mem.tokenizeAny(u8, query, " \t\r\n");
      var count: usize = 0;
      while (tokens.next()) |token| {
          if (count > 0) try out.appendSlice(gpa, " AND ");
          try appendQuotedToken(&out, gpa, token);
          count += 1;
      }
      if (count == 0) return error.InvalidArgument;
      return out.toOwnedSlice(gpa);
  }
  ```
- `grep.zig:352` — `appendQuotedToken`:
  ```zig
  fn appendQuotedToken(out: *std.ArrayList(u8), gpa: std.mem.Allocator, token: []const u8) !void {
      try out.append(gpa, '"');
      for (token) |byte| {
          if (byte == '"') {
              try out.append(gpa, '"');
              try out.append(gpa, '"');
          } else {
              try out.append(gpa, byte);
          }
      }
      try out.append(gpa, '"');
  }
  ```
- `grep.zig:365` — `describeEntry`:
  ```zig
  fn describeEntry(entry_kind: []const u8, label: []const u8) []const u8 {
      if (std.mem.eql(u8, entry_kind, "message")) return "msg";
      if (std.mem.eql(u8, entry_kind, "tool_args")) return "args";
      if (std.mem.eql(u8, entry_kind, "tool_result")) return "result";
      return label;
  }
  ```
- `grep.zig:372` — `formatEntryLabel`:
  ```zig
  fn formatEntryLabel(buf: *[128]u8, entry_kind: []const u8, label: []const u8) []const u8 {
      if (std.mem.eql(u8, entry_kind, "tree")) return "file listing";
      if (std.mem.eql(u8, entry_kind, "blame")) return "blame map";
      return std.fmt.bufPrint(buf, "{s}", .{label}) catch label;
  }
  ```

### `src/cli/recall.zig` — testable helpers

- `recall.zig:496` — `outcomeRank`:
  ```zig
  fn outcomeRank(raw: ?[]const u8) u8 {
      return switch (outcome_mod.parseLabel(raw)) {
          .failure => 0,
          .unknown => 1,
          .success => 2,
      };
  }
  ```
- `recall.zig:500` — `outcomeLabel`:
  ```zig
  fn outcomeLabel(raw: ?[]const u8) []const u8 {
      return outcome_mod.parseLabel(raw).label();
  }
  ```

### `src/cli/eval.zig` — testable helpers

- `eval.zig:670` — `parseLookahead`:
  ```zig
  fn parseLookahead(value: []const u8) !i64 {
      if (std.mem.eql(u8, value, "0")) return 0;
      if (value.len < 2) return error.InvalidArgument;
      const suffix = value[value.len - 1];
      const amount = try std.fmt.parseInt(i64, value[0 .. value.len - 1], 10);
      if (amount < 0) return error.InvalidArgument;
      return switch (suffix) {
          'h' => amount * 60 * 60 * 1000,
          'd' => amount * 24 * 60 * 60 * 1000,
          else => error.InvalidArgument,
      };
  }
  ```
- `eval.zig:568` — `countSessions`:
  ```zig
  fn countSessions(rows: []const store_mod.TimelineRow) i64 {
      var count: i64 = 0;
      var i: usize = 0;
      while (i < rows.len) : (i += 1) {
          if (i > 0 and std.mem.eql(u8, rows[i].session_id, rows[i - 1].session_id)) continue;
          count += 1;
      }
      return count;
  }
  ```

### Import coverage

`src/main.zig` already imports all three files in its test block:
```zig
_ = @import("cli/eval.zig");
_ = @import("cli/recall.zig");
_ = @import("cli/grep.zig");
```
No changes to `main.zig` are needed.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format | `zig build fmt` | exit 0 |
| Unit tests | `zig build test` | all pass, including new tests |
| Check | `zig build check` | exit 0 |

## Scope

**In scope**:
- `src/cli/grep.zig` — add test blocks for `buildMatchQuery`, `appendQuotedToken`, `describeEntry`, `formatEntryLabel`
- `src/cli/recall.zig` — add test blocks for `outcomeRank`, `outcomeLabel`
- `src/cli/eval.zig` — add test blocks for `parseLookahead`, `countSessions`

**Out of scope**:
- `src/main.zig` — already imports the three files in its test block
- `src/cli/stats.zig` — not in scope
- The `run` or `parseOptions` functions in any file — they require a full store
- Any changes to the helper signatures or behavior

## Git workflow

- Branch: `advisor/012-cli-unit-tests`
- Commit style: `test: add unit tests for grep/recall/eval helpers`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add tests to `src/cli/grep.zig`

Append the following test blocks to the end of `src/cli/grep.zig`, after all
existing code.

```zig
test "buildMatchQuery: single token becomes quoted" {
    const gpa = std.testing.allocator;
    const result = try buildMatchQuery(gpa, "hello");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"hello\"", result);
}

test "buildMatchQuery: multiple tokens joined with AND" {
    const gpa = std.testing.allocator;
    const result = try buildMatchQuery(gpa, "hello world");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"hello\" AND \"world\"", result);
}

test "buildMatchQuery: empty string returns InvalidArgument" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidArgument, buildMatchQuery(gpa, ""));
}

test "appendQuotedToken: escapes embedded quotes" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendQuotedToken(&out, gpa, "a\"b");
    const result = try out.toOwnedSlice(gpa);
    defer gpa.free(result);
    try std.testing.expectEqualStrings("\"a\"\"b\"", result);
}

test "describeEntry: maps known entry kinds" {
    try std.testing.expectEqualStrings("msg", describeEntry("message", "ignored"));
    try std.testing.expectEqualStrings("args", describeEntry("tool_args", "ignored"));
    try std.testing.expectEqualStrings("result", describeEntry("tool_result", "ignored"));
    try std.testing.expectEqualStrings("fallback", describeEntry("unknown", "fallback"));
}

test "formatEntryLabel: maps tree and blame" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("file listing", formatEntryLabel(&buf, "tree", "ignored"));
    try std.testing.expectEqualStrings("blame map", formatEntryLabel(&buf, "blame", "ignored"));
    try std.testing.expectEqualStrings("other", formatEntryLabel(&buf, "other", "other"));
}
```

**Verify**: `zig build test` → all existing tests pass, grep tests are included.

### Step 2: Add tests to `src/cli/recall.zig`

Append the following test blocks to the end of `src/cli/recall.zig`, after all
existing code.

```zig
test "outcomeRank: orders failure < unknown < success" {
    try std.testing.expect(outcomeRank("failure") < outcomeRank("success"));
    try std.testing.expect(outcomeRank("failure") < outcomeRank("unknown"));
    try std.testing.expect(outcomeRank("unknown") < outcomeRank("success"));
}

test "outcomeLabel: returns human-readable labels" {
    try std.testing.expectEqualStrings("failure", outcomeLabel("failure"));
    try std.testing.expectEqualStrings("unknown", outcomeLabel("unknown"));
    try std.testing.expectEqualStrings("success", outcomeLabel("success"));
}
```

**Verify**: `zig build test` → all tests pass, recall tests are included.

### Step 3: Add tests to `src/cli/eval.zig`

Append the following test blocks to the end of `src/cli/eval.zig`, after all
existing code.

```zig
test "parseLookahead: parses hours" {
    try std.testing.expectEqual(@as(i64, 3600000), try parseLookahead("1h"));
    try std.testing.expectEqual(@as(i64, 7200000), try parseLookahead("2h"));
}

test "parseLookahead: parses days" {
    try std.testing.expectEqual(@as(i64, 86400000), try parseLookahead("1d"));
    try std.testing.expectEqual(@as(i64, 172800000), try parseLookahead("2d"));
}

test "parseLookahead: zero is valid" {
    try std.testing.expectEqual(@as(i64, 0), try parseLookahead("0"));
}

test "parseLookahead: rejects invalid input" {
    try std.testing.expectError(error.InvalidArgument, parseLookahead("abc"));
    try std.testing.expectError(error.InvalidArgument, parseLookahead("-1h"));
    try std.testing.expectError(error.InvalidArgument, parseLookahead("3x"));
    try std.testing.expectError(error.InvalidArgument, parseLookahead(""));
}

test "countSessions: counts unique sessions only" {
    const rows = [_]store_mod.TimelineRow{
        .{ .origin = "a", .session_id = "s1", .turn_id = "t1", .hash = "h1", .timestamp = 1 },
        .{ .origin = "a", .session_id = "s1", .turn_id = "t2", .hash = "h2", .timestamp = 2 },
        .{ .origin = "a", .session_id = "s2", .turn_id = "t1", .hash = "h3", .timestamp = 3 },
    };
    try std.testing.expectEqual(@as(i64, 2), countSessions(&rows));
}

test "countSessions: empty slice returns 0" {
    const rows = [_]store_mod.TimelineRow{};
    try std.testing.expectEqual(@as(i64, 0), countSessions(&rows));
}
```

**Verify**: `zig build test` → all tests pass, eval tests are included.

## Test plan

- Tests are pure unit tests: no I/O, no store, no temp directories.
- Pattern to follow: `src/cli/init.zig:561-580` (hook installation tests).
- Verification: run `zig build test` — total passing test count should increase
  by 14 (6 grep + 2 recall + 6 eval).

## Done criteria

- [ ] `zig build fmt` exits 0
- [ ] `zig build test` exits 0; all new tests pass
- [ ] `zig build check` exits 0
- [ ] Only `src/cli/grep.zig`, `src/cli/recall.zig`, and `src/cli/eval.zig` were modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any of the helper function signatures have changed from the excerpts above.
- `outcome_mod.parseLabel` return type or `.label()` method is unavailable.
- `store_mod.TimelineRow` field names differ from the excerpt.
- `zig build test` fails because the test block in `main.zig` no longer imports
  one of the three files.

## Maintenance notes

- These tests are intentionally narrow. If a helper function gains new behavior
  (e.g., `buildMatchQuery` supports OR operators), the tests must be extended.
- `parseOptions` in each file remains untested — that requires a mock argument
  iterator or a CLI-level test. Consider a future plan for CLI integration tests
  using the test harness if the helpers get complex enough.

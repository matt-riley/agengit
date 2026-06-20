# Plan 003: Replace brittle substring-based object kind detection

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat bae6a6c..HEAD -- src/store/object.zig`
> If any in-scope file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `bae6a6c`, 2026-06-20

## Why this matters

`object.detectKind()` decides whether a stored object is a `tree`, `step`, `blame`, or `blob` by searching for literal substrings like `"type":"step"`. A source file whose content contains that exact substring is misclassified as a `step`. During `agit reindex` that causes a JSON parse failure and a wrong `objects.kind` row; integrity scans may also report false schema errors.

The fix keeps the fast substring filter but validates any match against the actual JSON `type` field before returning a structured kind.

## Current state

- `src/store/object.zig:118-126` — `detectKind` is:

```zig
pub fn detectKind(data: []const u8) []const u8 {
    if (std.mem.indexOf(u8, data, "\"type\":\"tree\"") != null) return "tree";
    if (std.mem.indexOf(u8, data, "\"type\":\"step\"") != null) return "step";
    if (std.mem.indexOf(u8, data, "\"type\":\"blame\"") != null) return "blame";
    return "blob";
}
```

- `src/cli/reindex.zig` uses `object.detectKind(data)` to populate the `objects.kind` cache, and `src/store/integrity.zig` uses it to validate scanned objects.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Typecheck / test | `zig build test` | exit 0, all tests pass |
| Format | `zig build fmt` | exit 0 |

## Scope

**In scope**:
- `src/store/object.zig`
- Tests inside `src/store/object.zig`

**Out of scope**:
- Callers in `src/cli/reindex.zig` and `src/store/integrity.zig` (they do not need changes).
- The object file format itself.

## Steps

### Step 1: Add a JSON-validating helper

In `src/store/object.zig`, add a private helper that parses just enough JSON to read the top-level `"type"` string value and compare it. Use `std.heap.page_allocator` for the short-lived parse; the result is discarded after comparison, so no ownership is returned.

Target shape:

```zig
fn jsonTopLevelTypeIs(data: []const u8, expected: []const u8) bool {
    const gpa = std.heap.page_allocator;
    var parsed = std.json.parseFromSlice(struct { @"type": ?[]const u8 = null }, gpa, data, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    const t = parsed.value.@"type" orelse return false;
    return std.mem.eql(u8, t, expected);
}
```

**Verify**: `zig build test` still passes.

### Step 2: Update `detectKind` to validate substring matches

Change `detectKind` so that a substring match only wins if the JSON top-level `type` field actually equals that value. Non-JSON data and blobs that happen to contain the literal will fall through to `"blob"`.

Target shape:

```zig
pub fn detectKind(data: []const u8) []const u8 {
    if (std.mem.indexOf(u8, data, "\"type\":\"tree\"") != null and jsonTopLevelTypeIs(data, "tree")) return "tree";
    if (std.mem.indexOf(u8, data, "\"type\":\"step\"") != null and jsonTopLevelTypeIs(data, "step")) return "step";
    if (std.mem.indexOf(u8, data, "\"type\":\"blame\"") != null and jsonTopLevelTypeIs(data, "blame")) return "blame";
    return "blob";
}
```

**Verify**: `zig build test` still passes.

### Step 3: Add regression tests

Append tests inside `src/store/object.zig`:

1. A blob whose content contains `"type":"step"` but is not valid JSON object must be classified as `"blob"`.
2. A plain text string that is not JSON must be `"blob"`.
3. A valid `Step`, `Tree`, and `Blame` object must still be classified correctly.

Model on the existing test:

```zig
test "detectKind classifies structured and raw objects" {
```

**Verify**: `zig build test` shows the new tests passing.

## Test plan

- `test "detectKind ignores literal type string inside a blob"`
- `test "detectKind still recognizes real structured objects"` (extend or replace the existing one if appropriate)

## Done criteria

- [ ] `jsonTopLevelTypeIs` helper exists and only parses when a substring match is found.
- [ ] `detectKind` returns `"blob"` for content that merely contains a `"type":"step"` substring.
- [ ] `detectKind` still returns `"tree"`, `"step"`, and `"blame"` for valid objects of those types.
- [ ] `zig build test` exits 0.
- [ ] `zig build check-fmt` exits 0.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- The Zig 0.16 parser rejects the `@"type"` struct-field syntax (in that case model the helper around `std.json.Scanner` instead).
- `detectKind` becomes measurably slower on the `bench/store.zig` benchmark (use the existing `bench-store` step to check).
- Any existing integrity-scan test breaks because it relied on the old substring behavior.

## Maintenance notes

The substring filter is preserved as an optimization so that most blobs are never parsed. If the object format ever adds a new structured kind, add the new substring + `jsonTopLevelTypeIs` pair to `detectKind` rather than changing the helper.

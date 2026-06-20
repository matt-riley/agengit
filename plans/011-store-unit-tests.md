# Plan 011: Add CAS round-trip unit tests to the store layer

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b2d0213..HEAD -- src/store/store.zig src/store/object.zig src/main.zig`
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

`src/store/store.zig` (1,593 LOC) is the trust anchor of agit: it handles
content-addressed writes, object reads, ref management, and index queries.
It has zero internal unit tests — the only coverage is indirect, through
e2e and integration tests that exercise it via CLI commands. Direct tests
for the core CAS primitives (blob/tree/step round-trips, prefix resolution)
catch data-corruption regressions immediately, with fast feedback and clear
failure diagnostics.

## Current state

- `src/store/store.zig:53` — `Store` struct (root `Io.Dir` + `Index`)
- `src/store/store.zig:62` — `pub fn open(io, repo_dir, gpa) !Store` — creates `.agit/` structure
- `src/store/store.zig:122` — `pub fn deinit(self, io)` — closes DB and root dir
- `src/store/store.zig:189` — `pub fn writeBlob(self, io, data) !Hash`
- `src/store/store.zig:215` — `pub fn readBlob(self, io, gpa, h) ![]u8` — caller owns slice
- `src/store/store.zig:197` — `pub fn writeTree(self, io, gpa, tree) !Hash`
- `src/store/store.zig:236` — `pub fn readTree(self, io, gpa, h) !std.json.Parsed(Tree)`
- `src/store/store.zig:205` — `pub fn writeStep(self, io, gpa, step) !Hash`
- `src/store/store.zig:243` — `pub fn readStep(self, io, gpa, h) !std.json.Parsed(Step)`
- `src/store/store.zig:250` — `pub fn resolvePrefix(self, io, gpa, prefix) !PrefixResolution`
- `src/store/object.zig:27` — `Tree` struct shape
- `src/store/object.zig:61` — `Step` struct shape
- `src/main.zig:206+` — test block already imports `store/store.zig`:
  ```zig
  _ = @import("store/store.zig");
  ```
  This means any `test` blocks added to `store.zig` are automatically compiled
  into the test binary. No change to `main.zig` is required.

### Conventions to follow

- Tests use `std.testing.allocator`, `std.testing.tmpDir(.{})`, and
  `const io = std.testing.io;` — see `src/hook.zig:454-480` for an exemplar.
- `Hash` values have a `.toHex()` method returning a `*const [64]u8`.
- `std.json.Parsed(T)` values must be `.deinit()`-ed when done.
- Error handling in tests uses `try std.testing.expect...`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Format | `zig build fmt` | exit 0 |
| Unit tests | `zig build test` | all pass, including new tests |
| Check | `zig build check` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `src/store/store.zig` — add `test` blocks for CAS round-trips and prefix resolution

**Out of scope** (do NOT touch):
- `src/main.zig` — already imports `store/store.zig` in its test block
- `src/store/index.zig` — separate plan
- `src/store/object.zig` — read-only reference for struct shapes
- Any CLI files or e2e tests

## Git workflow

- Branch: `advisor/011-store-unit-tests`
- Commit style: `test: add CAS round-trip tests for Store` (Conventional Commits)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add test blocks to `src/store/store.zig`

Append the following test blocks to the end of `src/store/store.zig`, after all
existing code. Each test creates a temporary directory, opens a Store, exercises
one primitive, and cleans up.

**Test 1 — Blob round-trip:**
```zig
test "Store blob write/read round-trip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".agit");
    var store = try Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const data = "hello, agit blob";
    const hash = try store.writeBlob(io, data);
    const read = try store.readBlob(io, gpa, hash);
    defer gpa.free(read);
    try std.testing.expectEqualStrings(data, read);
}
```

**Test 2 — Tree round-trip:**
```zig
test "Store tree write/read round-trip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".agit");
    var store = try Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    // Write a blob so we can reference it in the tree.
    const blob_data = "file contents";
    const blob_hash = try store.writeBlob(io, blob_data);

    const tree = Tree{
        .entries = &.{
            .{
                .path = "hello.txt",
                .blob = &blob_hash.toHex(),
                .mode = "100644",
                .size = blob_data.len,
            },
        },
    };
    const hash = try store.writeTree(io, gpa, tree);
    var parsed = try store.readTree(io, gpa, hash);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.entries.len);
    try std.testing.expectEqualStrings("hello.txt", parsed.value.entries[0].path);
    try std.testing.expectEqualStrings(&blob_hash.toHex(), parsed.value.entries[0].blob);
}
```

**Test 3 — Step round-trip:**
```zig
test "Store step write/read round-trip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".agit");
    var store = try Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const tree_hash = try store.writeBlob(io, "tree_marker");
    const step = Step{
        .parent = null,
        .tree = &tree_hash.toHex(),
        .session_id = "sess-1",
        .origin = "test-origin",
        .turn_id = "turn-1",
        .causes = &.{},
        .timestamp = 1234567890,
        .messages = &.{},
        .tool_calls = &.{},
    };
    const hash = try store.writeStep(io, gpa, step);
    var parsed = try store.readStep(io, gpa, hash);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("sess-1", parsed.value.session_id);
    try std.testing.expectEqualStrings("test-origin", parsed.value.origin);
    try std.testing.expectEqualStrings("turn-1", parsed.value.turn_id);
    try std.testing.expectEqual(@as(i64, 1234567890), parsed.value.timestamp);
}
```

**Test 4 — Prefix resolution finds object:**
```zig
test "Store resolvePrefix finds unique hash" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".agit");
    var store = try Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const data = "unique content for prefix test";
    const hash = try store.writeBlob(io, data);
    const hex = hash.toHex();

    // Full hash should resolve uniquely.
    const resolved = try store.resolvePrefix(io, gpa, &hex);
    try std.testing.expectEqual(hash, resolved.unique);
}
```

**Test 5 — Prefix resolution returns not_found:**
```zig
test "Store resolvePrefix returns not_found for unknown prefix" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".agit");
    var store = try Store.open(io, tmp.dir, gpa);
    defer store.deinit(io);

    const resolved = try store.resolvePrefix(io, gpa, "0000000000000000");
    try std.testing.expect(resolved == .not_found);
}
```

**Verify**: `zig build test` → all existing tests pass plus the 5 new tests.

## Test plan

- Tests are self-contained: each creates a `tmpDir`, opens a Store, exercises
  one write/read pair, asserts equality, and deinitializes.
- Pattern to follow: `src/hook.zig:454-480` (`openResolvedWorkspaceDir` tests).
- No new test files are created — tests live inline in `src/store/store.zig`.
- Verification command: `zig build test` → count of passing tests increases by 5.

## Done criteria

- [ ] `zig build fmt` exits 0
- [ ] `zig build test` exits 0; at least 5 new tests in `store.zig` pass
- [ ] `zig build check` exits 0
- [ ] Only `src/store/store.zig` was modified (`git status --short`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `src/store/store.zig` or `src/store/object.zig` struct definitions have drifted
  from the excerpts above (e.g., `Step`, `Tree`, `TreeEntry` field changes).
- `Store.open` or `Store.deinit` signatures differ from the excerpts.
- `zig build test` fails for any reason unrelated to the new test code.
- The Hash type no longer has `.toHex()` or `.fromHex()` available.

## Maintenance notes

- These tests create SQLite databases and `.agit/` subdirectories on disk.
  If the schema changes, the `Store.open` call will auto-migrate; existing
  round-trip tests should still pass because they exercise object storage,
  not index queries.
- If `open` gains new required initialization, these tests may need updating.
- Future plans for index-query tests can build on this pattern.

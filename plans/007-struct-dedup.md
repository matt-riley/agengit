# Plan 007: De-duplicate HookFailureDetails and HookFailureLogEntry structs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 07fffa1..HEAD -- src/recorder.zig src/hook.zig src/hook/runner.zig`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `07fffa1`, 2026-06-20

## Why this matters

`src/recorder.zig` defines two structs that carry nearly identical hook-failure
metadata: `HookFailureDetails` (the public API — what callers pass in) and
`HookFailureLogEntry` (the serialization shape — what gets written to the log).
These have ~15 overlapping fields. Every change to one must be mirrored in the
other, which creates maintenance overhead and a risk of drift: add a field to
`HookFailureDetails` and forget to map it in `HookFailureLogEntry`, and the new
data silently disappears from the log. Consolidating eliminates the manual
field-by-field mapping in `logHookFailure`.

## Current state

- `src/recorder.zig:19-33` — `HookFailureDetails` struct (16 fields)
- `src/recorder.zig:35-57` — `HookFailureLogEntry` struct (17 fields, includes `ts`, `level`, `context`, `error_kind`, `error_msg` not in `HookFailureDetails`)
- `src/recorder.zig:517-554` — `logHookFailure` function that manually maps
  fields from `HookFailureDetails` to `HookFailureLogEntry`

The overlapping fields between the two structs:
- `agent`, `code`, `message`, `session_id`, `event_name`, `field`
- `payload_bytes`, `payload_snippet`, `parse_path`, `parse_offset`, `parse_line`, `parse_column`
- `max_payload_bytes`, `staging_key`, `quarantine_path`

The `HookFailureLogEntry` adds: `ts`, `level`, `context`, `event` (aliases `event_name`), `error_kind` (from `err` parameter), `error_msg` (from `details.message`).

Current `logHookFailure` body (the mapping we want to eliminate):
```zig
// src/recorder.zig:517-554
pub fn logHookFailure(
    self: *Recorder,
    io: std.Io,
    context: []const u8,
    err: anyerror,
    details: HookFailureDetails,
) void {
    var aw: std.Io.Writer.Allocating = .init(self.gpa);
    defer aw.deinit();

    std.json.Stringify.value(
        HookFailureLogEntry{
            .ts = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            .agent = details.agent orelse context,
            .context = context,
            .event = details.event_name,
            .session_id = details.session_id,
            .error_kind = @as([]const u8, @errorName(err)),
            .error_msg = details.message,
            .payload_size = details.payload_bytes,
            .payload_snippet = details.payload_snippet,
            .parse_path = details.parse_path,
            .parse_offset = details.parse_offset,
            .parse_line = details.parse_line,
            .parse_column = details.parse_column,
            .code = details.code,
            .message = details.message,
            .event_name = details.event_name,
            .field = details.field,
            .payload_bytes = details.payload_bytes,
            .max_payload_bytes = details.max_payload_bytes,
            .staging_key = details.staging_key,
            .quarantine_path = details.quarantine_path,
        },
        .{},
        &aw.writer,
    ) catch return;
    const entry_json = aw.writer.buffered();

    self.appendHookLog(io, entry_json) catch return;
}
```

Note the deliberate duplication: `details.event_name` mapped twice (once to
`event`, once to `event_name`); `details.payload_bytes` mapped twice (once to
`payload_size`, once to `payload_bytes`); `details.message` mapped twice (once
to `error_msg`, once to `message`). This is intentional — the log format
includes both legacy field names and structured names — but amplifies the cost
of the duplicated structs.

Callers of `logHookFailure`:
- `src/recorder.zig:76-78` — `logHookFailureFromCwd`
- `src/recorder.zig:83-89` — `logHookFailureFromDir`
- `src/recorder.zig:534-537` — `logError` (thin wrapper)
- `src/recorder.zig:448-452` — `recordBlameForStep` error path
- `src/recorder.zig:501-505` — `recordBlameForStep` error path
- `src/recorder.zig:650` — `consumeStaging` quarantine path
- `src/hook/runner.zig:129-134` — `processPayload` error path
- `src/hook/runner.zig:164-170` — `processPayload` workspace fallback
- `src/hook/runner.zig:170-176` — `processPayload` recovery turn

## Commands you will need

| Purpose   | Command                  | Expected on success |
|-----------|--------------------------|---------------------|
| Format    | `zig build fmt`          | exit 0              |
| Unit test | `zig build test`         | all pass            |
| E2E test  | `zig build test-e2e`     | all pass            |
| Full check| `zig build check`        | exit 0              |

## Scope

**In scope** (the only files you should modify):
- `src/recorder.zig` — merge the two structs, simplify `logHookFailure`
- `src/hook.zig` — the `FailureContext` struct shares some fields; check if
  it can also use the merged shape (but do NOT change callers unless the change
  is a strict simplification)

**Out of scope** (do NOT touch):
- `src/hook/runner.zig` — the `reportFailure` function builds `FailureContext`
  separately; keep it as-is unless the field alignment makes a natural
  consolidation obvious.
- The JSON log format — must remain backward-compatible (existing
  `hook-error.log` entries must still parse). The serialized field names
  (`event`, `error_kind`, `error_msg`, `payload_size`) must stay identical.
- Any other `.zig` files.

## Git workflow

- Branch: `advisor/007-struct-dedup`
- Commit style: `refactor: consolidate hook failure structs`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Inline `HookFailureDetails` into `HookFailureLogEntry`

In `src/recorder.zig`, merge the two structs into a single `HookFailureLogEntry`
that serves both purposes:

- Move `ts`, `level`, `context`, `error_kind`, `error_msg` fields into the
  unified struct (already present in `HookFailureLogEntry`).
- Keep all optional fields from `HookFailureDetails` (with `= null` defaults).
- Create a type alias: `pub const HookFailureDetails = HookFailureLogEntry;` so
  existing callers still compile without changes.

The unified struct (pseudocode):
```zig
pub const HookFailureLogEntry = struct {
    // Runtime fields (set by logHookFailure, not by callers)
    ts: i64 = 0,
    level: []const u8 = "error",
    context: []const u8 = "",
    error_kind: []const u8 = "unknown",

    // Caller-provided fields (was HookFailureDetails)
    agent: ?[]const u8 = null,
    code: []const u8 = "hook_error",
    message: []const u8 = "hook failed",
    session_id: ?[]const u8 = null,
    event_name: ?[]const u8 = null,
    field: ?[]const u8 = null,
    payload_bytes: ?usize = null,
    payload_snippet: ?[]const u8 = null,
    parse_path: ?[]const u8 = null,
    parse_offset: ?usize = null,
    parse_line: ?usize = null,
    parse_column: ?usize = null,
    max_payload_bytes: ?usize = null,
    staging_key: ?[]const u8 = null,
    quarantine_path: ?[]const u8 = null,

    // Legacy log-format aliases (set in logHookFailure for backward compat)
    event: ?[]const u8 = null,
    error_msg: []const u8 = "",
    payload_size: ?usize = null,
};

pub const HookFailureDetails = HookFailureLogEntry;
```

**Verify**: `zig build test` → all pass (unit tests compile against
`HookFailureDetails` type).

### Step 2: Simplify `logHookFailure`

Replace the manual field-by-field mapping with a direct assignment from
`details`:

```zig
pub fn logHookFailure(
    self: *Recorder,
    io: std.Io,
    context: []const u8,
    err: anyerror,
    details: HookFailureDetails,
) void {
    var entry = details;
    entry.ts = std.Io.Timestamp.now(io, .real).toMilliseconds();
    entry.context = context;
    entry.agent = details.agent orelse context;
    entry.error_kind = @as([]const u8, @errorName(err));
    // Legacy log-format fields
    entry.event = details.event_name;
    entry.error_msg = details.message;
    entry.payload_size = details.payload_bytes;

    var aw: std.Io.Writer.Allocating = .init(self.gpa);
    defer aw.deinit();
    std.json.Stringify.value(entry, .{}, &aw.writer) catch return;
    const entry_json = aw.writer.buffered();
    self.appendHookLog(io, entry_json) catch return;
}
```

**Verify**: `zig build test` → all pass. Specifically, the
`test "logError: writes a JSON line to hook-error.log"` and
`test "logError: appends to existing log"` tests must still pass with identical
log output (the serialized JSON must be byte-identical to before).

### Step 3: Run full test suite

**Verify**: `zig build check` → exit 0; `zig build test-e2e` → all pass.

### Step 4: Check the log output format hasn't changed

Run a manual sanity check:
```sh
zig build test 2>&1 | grep -c "All [0-9]* tests passed"
```
Must report that all tests passed. The hook failure log tests in `recorder.zig`
verify the JSON shape.

## Test plan

- Existing unit tests cover `logError`, `logHookFailure`, and the JSON output
  format. These must continue to pass with identical output.
- No new tests needed — this is a pure refactor.
- Verify with: `zig build test` → all pass.

## Done criteria

- [ ] `zig build check` exits 0
- [ ] `zig build test` exits 0; all tests pass
- [ ] `HookFailureDetails` is a type alias, not a standalone struct
- [ ] `logHookFailure` does NOT manually map 15+ individual fields
- [ ] `zig build test-e2e` exits 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The code at the locations in "Current state" doesn't match the excerpts
  (the codebase has drifted since this plan was written).
- Any existing test fails after the refactor — especially the JSON log format
  tests.
- The `FailureContext` struct in `src/hook.zig` creates unresolvable conflicts
  that would require changing callers beyond `src/recorder.zig`.
- The serialized JSON output changes in any way (diff the log lines).

## Maintenance notes

- If new fields are added to the hook failure details in the future, only one
  struct needs updating. The `logHookFailure` function only sets runtime fields
  (`ts`, `context`, `error_kind`) and legacy aliases.
- The `HookFailureDetails` alias preserves backward compatibility for all
  callers. Future cleanup could remove the alias in a follow-up.
- Review: confirm that the legacy log fields (`event`, `error_msg`,
  `payload_size`) are still populated identically. The `doctor` command reads
  `hook-error.log` and may depend on these field names.

# ADR 006: Crash-safe agent config writes

**Status:** Accepted
**Date:** 2026-05-25

## Context

`agit init` and `agit uninstall` mutate user-owned JSON files that other tools
depend on at every prompt:

- `~/.claude/settings.json`
- `~/.codex/hooks.json`
- `~/.gemini/settings.json`

The current flow in `src/cli/init.zig` (~97–140) and `src/cli/uninstall.zig`
(~67–74) is roughly:

1. Read the existing file (if any).
2. Write a `*.agit.bak` backup.
3. Parse and mutate.
4. Write the new config back over the original path.

There are three concrete failure modes:

- **Crash mid-write.** Steps (2) and (4) are non-atomic writes to the live path.
  A SIGKILL, OOM, or power loss between the backup and the final flush can leave
  the agent with a half-written settings file. The next time Claude/Codex/Gemini
  starts, it refuses to load.
- **No rollback on failure.** If the final write fails after the backup is in
  place, nothing restores the original. The user is told `init` failed but the
  shell still has a broken config.
- **Uninstall silently skips malformed JSON** (`src/cli/uninstall.zig:46–50`).
  If the user hand-edited the file into something invalid, `agit uninstall`
  reports nothing and changes nothing. There is no signal that the hook is
  still wired up.

ADR 005 already commits us to "fail loudly if that backup or the final config
write fails" and to "refuse malformed or non-object existing JSON". This ADR
specifies how.

## Decision

All edits to agent config files go through a single helper with the following
contract:

1. **Read and parse first.** If the file exists but is not a JSON object, fail
   with a typed error that names the file, the parse offset, and a suggested
   fix. `init` requires `--force` to overwrite; `uninstall` emits a warning and
   leaves the file untouched.
2. **Backup after successful parse.** The `.agit.bak` copy is only written once
   we know the original is valid (or the user passed `--force`).
3. **Write through `tmp` + `rename()`.** The new content is written to a
   sibling file in the same directory (`settings.json.agit-tmp-<pid>`), fsynced,
   then atomically renamed onto the target.
4. **Rollback on rename failure.** If `rename()` fails, the helper deletes the
   tmp file and surfaces the original error with rollback context. If the
   rename succeeded but a follow-up step fails, the helper restores from
   `*.agit.bak` and reports both errors.
5. **Directory fsync.** After rename, the parent directory is fsynced (see
   ADR 008) so the new inode survives crash.

The helper lives in `src/util/atomic_json.zig` and is reused by `init`,
`uninstall`, and any future config-mutating command.

## Plan

1. Add `src/util/atomic_json.zig` exposing:
   - `pub fn loadObject(gpa, path) !?std.json.Value` — returns `null` for
     missing, a `MalformedJson{path, offset, line}` error otherwise.
   - `pub fn writeAtomic(gpa, path, value, opts) !void` — handles tmp +
     rename + fsync + rollback.
   - `pub fn backupOnce(path) !void` — writes `*.agit.bak` only if absent or
     `--force` was specified.
2. Refactor `src/cli/init.zig` to call the helper for each agent. Remove the
   inline `createDirPath`/`writeFile` calls and replace ad-hoc error paths with
   typed errors that include the offending agent name and absolute path.
3. Refactor `src/cli/uninstall.zig` the same way. Malformed JSON becomes a
   user-visible warning, not a silent return.
4. Validate `$HOME` and each agent's config parent directory up front in
   `init`; if any are missing/unwritable, fail before touching anything.
5. Update `doctor` to verify backups exist for any managed config and to flag
   leftover `.agit-tmp-*` files as evidence of a previous crash.

## Testing

- Unit tests for `atomic_json.zig`: valid object roundtrip, missing file,
  malformed JSON, non-object root, unwritable parent dir, simulated rename
  failure (inject via test allocator + temp dir).
- Integration tests under `tests/` (see ADR 014) that:
  - Run `agit init` against a temp `HOME` populated with valid configs and
    assert hooks are present, backups exist, and no `.agit-tmp-*` leftovers.
  - Run `agit init` against malformed JSON without `--force` and assert it
    refuses, prints offset, and leaves the file byte-identical.
  - Run `agit uninstall` against malformed JSON and assert the warning is
    emitted.
  - Crash mid-write by killing the process between tmp write and rename
    (via a debug-build hook env var) and assert the original survives.

## Risks and tradeoffs

- More code paths to maintain than the current "just write it" approach.
- `rename()` semantics on Windows are different; agengit is Unix-only today
  but we should not paint ourselves into a corner. Keep the helper Posix-only
  for now and gate Windows behind a separate ADR.
- Some agents may watch their config file for changes (inotify); a rename
  replaces the inode and may or may not trigger their reload. Acceptable for
  v1 since these files are read at agent startup.

## Consequences

- Partial writes stop being a class of bug.
- Users get an actionable error pointing at the exact file and offset when
  their config is malformed, instead of `error.InvalidConfigJson`.
- `doctor` gains a real crash-recovery signal.
- `init` and `uninstall` share one code path, which makes the next adapter
  (Pi, Copilot CLI) cheaper to add.

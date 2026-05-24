# ADR 005: Hook Installation Contract

**Status:** Accepted

## Context

`agit init` must write hook configuration into agent config files (e.g., `.claude/settings.json`, Codex CLI config, Gemini CLI config). These files are user-owned and may contain existing settings. Incorrect writes can break the agent for the user.

## Decision

### Sentinel-managed blocks

All `agit`-managed content is wrapped in clearly marked sentinel comments:

```
// BEGIN AGIT MANAGED — do not edit this block manually
...
// END AGIT MANAGED
```

For JSON config files that don't support comments, `agit` uses a dedicated `"_agit"` key in the relevant config object.

### Backup before write

Before modifying any agent config file, `agit` creates a `.bak` copy:

```
.claude/settings.json.agit.bak
```

The backup is a verbatim copy of the file as it existed before `agit` touched it.

### Idempotent init

`agit init` can be run multiple times safely:

- If a sentinel block already exists, it is replaced in-place with the current canonical content.
- The rest of the file is preserved exactly.
- Re-running after a binary update refreshes the absolute path in hook configs.

### Absolute path requirement

Hook commands in agent configs must use the **absolute path** to the `agit` binary (discovered at `agit init` time via `std.fs.selfExePath`). Relying on `PATH` is fragile across login shells, non-interactive shells, and shell re-configuration.

### Uninstall

`agit uninstall`:

- Removes only sentinel-managed blocks.
- Preserves all user-owned content in agent config files.
- Reports a warning if a managed block was manually edited (content drift detected by comparing against the expected canonical block).
- Does not delete `.agit/` — store contents are preserved.

### Drift detection

Before each `agit init` re-run, the installer checks whether a managed block has been manually modified since the last install. If drift is detected, the user is warned and asked to confirm overwrite.

## Consequences

- User config files are never silently clobbered.
- `agit init` can be safely re-run after binary updates.
- `agit uninstall` leaves the system exactly as it was before `agit init` (plus the `.bak` files).
- The absolute-path requirement means hook configs become stale if the binary moves; `agit doctor` detects and reports this.

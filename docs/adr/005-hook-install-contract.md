# ADR 005: Install hooks without trampling user config

**Status:** Accepted
**Editorial note:** Reworded on 2026-05-25 for clarity; the decision is unchanged.

## Context

`agit init` writes hook configuration into user-owned files such as:

- `~/.claude/settings.json`
- `~/.codex/hooks.json`
- `~/.gemini/settings.json`

Those files may already contain carefully arranged user settings. A recorder that clobbers them would be about as welcome as a goose in a server room.

## Decision

`agit init` must:

- detect supported agent binaries on `PATH`;
- create a backup before changing an existing config file;
- write the absolute path to the current `agit` binary;
- add `_agit` metadata so `doctor` and `uninstall` can recognize managed config;
- preserve unrelated user-owned config keys;
- be safe to run more than once.

`agit uninstall` must:

- remove only hooks that match the recorded `agit` binary metadata;
- remove `_agit` metadata when managed hooks are gone;
- preserve user-owned settings and hooks;
- leave `.agit/` data in place.

## Consequences

- Users can try `agit` without handing it the keys to every config cupboard.
- Binary moves can make hook paths stale; `agit doctor` should report that mismatch.
- Backups may remain after uninstall, which is preferable to losing user config.
- Hook config formats should stay as close as possible to each agent's native shape.

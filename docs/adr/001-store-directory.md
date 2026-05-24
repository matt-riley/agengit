# ADR 001: Store Directory — `.agit/`

**Status:** Accepted

## Context

`agit` needs a well-known directory to store its content-addressed objects, refs, SQLite index, config, and logs. The upstream project `regent-vcs/re_gent` uses `.regent/`. A compatible path would allow cross-tool workflows but could silently mix data between implementations before compatibility is proven.

## Decision

Use `.agit/` as the exclusive store directory for v1.

- Config: `.agit/config.json`
- Objects: `.agit/objects/`
- Refs: `.agit/refs/sessions/`
- Blame: `.agit/blame/`
- Index: `.agit/index.db`
- Logs: `.agit/log/hook-error.log`
- Ignore file: `.agitignore`

A future migration path to read/write `.regent/` will be considered only after a dedicated compatibility plan is written and byte-level format parity is verified.

## Consequences

- Users of `re_gent` will not accidentally mix stores with `agit` v1.
- A future migration command (`agit migrate-from-regent` or similar) can handle adoption.
- `.agit/` should be added to `.gitignore` (never committed to the repository it observes).

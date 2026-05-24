# ADR 002: Configuration Format — JSON

**Status:** Accepted

## Context

`agit` needs a machine-readable config file at `.agit/config.json`. Candidates were TOML and JSON.

- TOML is the upstream `re_gent` choice. However, Zig 0.16's standard library has no TOML parser. Adding a TOML dep just for config introduces build complexity.
- JSON is natively handled by `std.json` in Zig 0.16 with no additional dependencies.
- JSON also matches the config ecosystems of Claude Code (`.claude/settings.json`), Google Gemini CLI, and Pi.

## Decision

Use JSON for all `agit` configuration files:

- `.agit/config.json` — store-level config (schema version, ignore overrides, log level)
- Hook payloads are always JSON (agent-mandated)
- Internal object serialization (trees, steps) uses JSON for inspectability

The config schema is versioned via a top-level `"schema_version"` field.

## Consequences

- No third-party TOML dependency needed for config.
- Config files are human-readable and easy to emit from any language.
- `re_gent` TOML configs are not directly importable; a conversion tool may be needed for migration.

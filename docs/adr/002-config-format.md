# ADR 002: Use JSON for configuration and objects

**Status:** Accepted
**Editorial note:** Reworded on 2026-05-25 for clarity; the decision is unchanged.

## Context

`agit` needs machine-readable data for local config, hook payloads, and inspectable object serialization.

TOML was considered because `re_gent` uses it. JSON was chosen because Zig 0.16 includes `std.json`, and the agents `agit` integrates with already live in JSON-heavy ecosystems.

## Decision

Use JSON for `agit`-owned structured data:

- `.agit/config.json` if store-level config is needed;
- agent hook payload parsing;
- tree and step object serialization;
- hook metadata such as the installed `agit` binary path.

Version JSON schemas with an explicit schema/version field where the file format needs migrations.

## Consequences

- No TOML parser dependency is required.
- Stored objects remain easy to inspect with ordinary tools.
- `re_gent` TOML config is not directly importable.
- Compatibility tooling, if added later, must convert between formats deliberately.

# ADR 018: Build, format, and lint coverage

**Status:** Implemented
**Date:** 2026-05-25

## Context

`build.zig:53–65` defines `fmt` and `check-fmt` steps that operate only on
`src/` and `build.zig`. That misses:

- `tests/` (currently empty, but ADR 014 fills it).
- `docs/` markdown — no link or fence check.
- `build.zig.zon` — not formatted at all.
- Top-level metadata files like `release-please-config.json` and the
  manifest — no schema check.

Three concrete consequences:

1. Tests added under `tests/` will not be format-checked, so style drifts.
2. Broken markdown links in `docs/` and `README.md` ship unnoticed.
3. A typo in `release-please-config.json` only surfaces when a release
   PR is opened — sometimes weeks later.

## Decision

1. Extend `build.zig`'s `fmt` and `check-fmt` to cover `src/`, `tests/`,
   `build.zig`, and any `*.zig` under `bench/`.
2. Add a `build.zig` step `check-docs` that runs a thin markdown link
   checker over `README.md`, `CHANGELOG.md`, and `docs/**/*.md`. Use
   `lychee` invoked through `zig build` (or a tiny Zig wrapper) so CI
   and local runs share the same command.
3. Add a `check-config` step that validates JSON files
   (`release-please-config.json`, `.release-please-manifest.json`) against
   the well-known release-please schema (vendored, since we can't fetch
   network in CI without setup).
4. Wire all three into `zig build check` as the umbrella target. CI runs
   `zig build check` plus tests.

## Plan

1. Update `build.zig` to enumerate the wider format set.
2. Add `tools/check-docs.zig` (or a shell wrapper invoking `lychee`).
3. Vendor the release-please JSON schema under
   `tools/schema/release-please.json` and add a `check-config.zig` that
   parses it and validates the configs.
4. Update `.github/workflows/ci.yml` to call `zig build check`.
5. Document the new steps in `docs/adr/018-...` (this ADR) and in
   `CONTRIBUTING.md` (out of scope here, tracked separately).

## Testing

- Run `zig build check` locally against the current tree; expect zero
  failures after migration.
- Add an intentional broken link to a sandbox markdown file in a feature
  branch and confirm CI catches it.
- Add a malformed entry to a copy of `release-please-config.json` in a
  branch and confirm `check-config` fails.

## Risks and tradeoffs

- Markdown link checking can be flaky when external URLs go down. We
  configure the checker to whitelist or treat external 5xx as a warning,
  not a failure.
- Adding `lychee` is one more tool to install in CI. The release-please
  schema check is pure Zig so it adds no runtime dependency.
- Format-checking `tests/` slows the format step slightly; negligible.

## Consequences

- Documentation drift gets caught at PR time.
- Release configuration errors surface immediately instead of at the
  next release attempt.
- Test code gets the same style discipline as source code.
- A single `zig build check` is the canonical pre-push command, which
  simplifies `CONTRIBUTING.md` and contributor onboarding.

# ADR 019: Keep README, `--help`, and behaviour in sync

**Status:** Proposed
**Date:** 2026-05-25

## Context

`README.md` describes commands and behaviour that the CLI does not always
match:

- README implies `blame` is fully working in the everyday commands list;
  the implementation has rough edges that aren't documented.
- README documents `init` refusing malformed JSON, but the user-facing
  message (`error.InvalidConfigJson`) does not match the polished narrative
  in the README.
- The platform install table lists four archives, but the release workflow
  builds only two until ADR 013 lands.
- `agit <cmd> --help` does not exist for several commands (see ADR 012),
  yet the README implies it does.

This drift is exactly the kind of friction that erodes trust in a tool
that bills itself as "the little black box for AI coding sessions." If
the box lies about its own controls, users assume it lies about its
contents too.

## Decision

1. **Single source of truth per command.** Each command's `UsageSpec`
   (introduced in ADR 012) declares synopsis, options, and examples.
   README rendering pulls from these specs at doc-generation time.
2. **`zig build docgen`** produces a generated section of `README.md`
   listing every command, its synopsis, and one example. The section is
   delimited by HTML comment markers; the docgen step rewrites only
   between markers and leaves prose untouched.
3. **CI verifies docgen is up to date** by running it and asserting `git
   diff --exit-code` against `README.md`.
4. **`agit <cmd> --help` matches the README** by construction, because
   both render from the same `UsageSpec`.
5. **Roadmap markers in README** (e.g. "Pi support coming") are tagged
   with a single explicit list rather than scattered through prose, so
   readers can find what is actually shipping.

## Plan

1. Land ADR 012 first (typed `UsageSpec`).
2. Add `tools/docgen.zig` that:
   - imports each command's `UsageSpec`,
   - renders a markdown block,
   - writes it between `<!-- BEGIN COMMANDS -->` and
     `<!-- END COMMANDS -->` markers in `README.md`.
3. Add `zig build docgen` and `zig build check-docgen` steps. The check
   variant fails if the generated section is stale.
4. Wire `check-docgen` into the umbrella `zig build check` (ADR 018).
5. Audit and rewrite the README's "Status" and "Everyday commands"
   sections to reflect what genuinely ships today; move roadmap items to
   a dedicated "Roadmap" section.
6. Cross-check `docs/adr/*` for references to behaviour that may have
   shifted (e.g. ADR 005 vs. the implementation in `init.zig` after
   ADR 006 lands).

## Testing

- The `check-docgen` step is itself the test.
- Add a regression test that runs `agit <cmd> --help` for every command
  and asserts the synopsis matches the README's generated block (parsed
  by markers).

## Risks and tradeoffs

- A regenerated README means contributors must run `zig build docgen`
  for command-affecting changes. Documented in `CONTRIBUTING.md`.
- Generated sections in human-edited markdown can be fiddly. We isolate
  the generated range with explicit markers and keep prose around them
  free-form.
- README is the front door of the repo; aggressive automation here is
  worth doing once and then leaving alone.

## Consequences

- README, `--help`, and actual command behaviour stop drifting.
- New contributors get a single place to add a command (its
  `UsageSpec`) and everything else flows from there.
- The "Roadmap" vs "Today" distinction is explicit, which sets
  expectations honestly for a v1 tool.
- Future ADRs about new commands include "update the UsageSpec" as a
  concrete step rather than a vague "and update the docs" footnote.

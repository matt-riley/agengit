# ADR 017: Deduplicate hook command implementations

**Status:** Implemented
**Date:** 2026-05-25

## Context

There are currently four hook command files:

- `src/cli/claude_hook.zig` (111 LOC)
- `src/cli/claude_tool_batch_hook.zig` (145 LOC)
- `src/cli/codex_hook.zig` (194 LOC)
- `src/cli/gemini_hook.zig` (133 LOC)

They share roughly 80% of their structure: read stdin, parse JSON, extract
session/turn/event metadata, build a step value, hand it to the recorder,
report failure on the hook-error log. The differences are in:

- the field names in the payload,
- how tool calls/results are extracted,
- which event names map to which recorder step kinds.

Adding a fifth adapter (Pi or GitHub Copilot CLI is on the roadmap per
README) means copy-pasting this scaffolding again. That is the kind of
duplication that quietly drifts: a bug fixed in `claude_hook.zig` doesn't
land in `codex_hook.zig`.

## Decision

Extract the common scaffolding into a `hook.runAdapter(adapter)` driver.
Each agent contributes only an adapter struct that names:

- the event-name mapping,
- a `parsePayload(json) !Payload` function,
- a `buildStep(payload) !Step` function.

The driver owns:

- stdin read + payload buffering + size cap (ADR 011),
- parse-error reporting,
- recorder open/close + lock acquisition (ADR 009),
- success and failure logging.

## Implemented design

The shipped contract lives in `src/hook/Adapter.zig`:

```zig
pub const Adapter = struct {
  name: []const u8,
  origin: []const u8,
  events: []const EventMapping,
  parseArgs: ?*const fn (iter, diagnostic) anyerror![]const u8 = null,
  parsePayload: ?*const fn (arena, payload, route, diagnostic) anyerror!ParsedPayload,
  buildStep: ?*const fn (arena, parsed, diagnostic) anyerror!BuildPlan,
};
```

- `src/hook/runner.zig` owns the shared fail-open flow: CLI arg routing,
  payload read + malformed/oversized reporting, recorder open/close,
  normalization, `upsertSession`, workspace-fallback logging, recovery-turn
  logging, and recorder dispatch.
- `src/hook/payload.zig` now holds the shared tool-payload stringification and
  malformed-tool preservation helpers.
- Adapters live under `src/hook/adapters/`. Claude exports two adapter
  constants from one file (`hook_adapter` and `tool_batch_adapter`) because the
  integration still has two CLI entrypoints, while Codex and Gemini each export
  one adapter.
- `src/hook/adapters/registry.zig` is the static registration point used by the
  conformance test. Adding a new adapter now means:
  1. one new adapter file under `src/hook/adapters/`,
  2. one thin CLI shim under `src/cli/`,
  3. one new registry entry,
  4. one fixture set / adapter test file update.

## Testing

- Unit tests per adapter: feed a golden payload, assert the produced
  build plan matches the expected recorder step(s).
- The existing hook integration tests (ADR 014) cover the runner path
  end-to-end.
- A trait-conformance test that asserts every registered adapter
  declares non-empty `events`, a non-null `parsePayload`, and a
  non-null `buildStep`.

## Risks and tradeoffs

- Function pointers in the adapter struct cost a little type safety
  vs. `comptime` dispatch. We accept this for the cleaner registration
  surface. If perf benchmarks ever flag it, we switch to a
  `comptime`-known table.
- The refactor touches every hook code path, so it must land *after*
  the e2e test suite (ADR 014) is in place to catch regressions.

## Consequences

- ~400 LOC of duplicated scaffolding collapses to ~100 LOC of runner
  plus ~30 LOC per adapter.
- A bug fix in the runner benefits every agent automatically.
- Adding Pi/Copilot CLI becomes a focused adapter file plus a fixture
  set, not a fourth copy of the same logic.
- Documentation of the adapter contract sets the bar for any future
  contribution: "look at `src/hook/adapters/codex.zig` and copy the shape."

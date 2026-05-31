# ADR 028: Observer-based integrations for agents without lifecycle hooks

**Status:** Partially superseded — see Update (2026)
**Date:** 2026-05-25

## Update (2026): Copilot and Pi ship as hook adapters

This ADR assumed GitHub Copilot CLI and Pi lacked a usable lifecycle-hook shape
and would require the observer framework. That assumption proved wrong for both:

- **GitHub Copilot CLI** exposes a `~/.copilot/hooks.json` config with
  `userPromptSubmitted`/`postToolUse`/`agentStop` command hooks that deliver
  JSON payloads on stdin — the same model as Codex. It is implemented as a
  standard hook adapter (`src/hook/adapters/copilot.zig`), not an observer.
- **Pi** auto-discovers JavaScript extensions under `~/.pi/agent/extensions/`.
  `agit init` writes a generated, self-contained `agit-recorder.js` that
  subscribes to Pi lifecycle events and shells out to `agit pi-hook` with a
  normalized payload. This is a generated-extension install kind
  (`install_kind = .js_extension` in `src/cli/init_plan.zig`) feeding the same
  hook adapter pipeline (`src/hook/adapters/pi.zig`), not an observer.

The observer framework below remains the intended architecture for genuinely
hookless agents (file/log/IPC-only state), and the experimental
`agit observe --once` path is unchanged. Only the specific Pi/Copilot targeting
in the original decision is superseded.

## Context

Current capture support is hook-driven:

- Claude Code hooks,
- Codex CLI hooks,
- Gemini CLI hooks.

The roadmap names Pi and GitHub Copilot CLI as future targets, but those agents
do not currently have the same public lifecycle-hook shape. Copying the hook
adapter model into those integrations would either be impossible or would depend
on unstable private behavior.

The code already benefits from a shared recorder pipeline. The missing decision
is how non-hook sources feed that pipeline without making `agit init` install
hidden background processes.

## Decision

Introduce an opt-in observer framework for agents that expose session state
through files, logs, local IPC, or future MCP-style callouts rather than hooks.

1. **Observer sources:** add `src/observer/` with source adapters that poll or
   watch an agent-specific state location and emit the same `NormalizedEvent`
   contract defined in ADR 024.
2. **Explicit command:** observers run only through explicit commands such as
   `agit observe <agent>` or a documented service wrapper. `agit init` may
   write config hints, but it must not start hidden long-running processes.
3. **Checkpoint state:** each observer stores watermarks under
   `.agit/observers/<agent>.json` so restarts resume without duplicating events.
4. **Backpressure and rate limits:** observers batch events, cap file reads, and
   hand off to the recorder with the same lock and durability rules as hooks.
5. **Privacy policy:** observers obey the `.agit/config.json` capture policy
   from ADR 026 before writing prompts, tool arguments, results, or snapshots.
6. **Adapter maturity:** each observer starts behind an experimental marker
   until its source format is documented and covered by fixtures.

## Plan

1. Define `ObserverSource` and `ObserverCheckpoint` types.
2. Implement a fake file-backed observer in tests before adding a real agent.
3. Add `agit observe --once <source-fixture>` for deterministic e2e validation.
4. Research Pi session-state files and Copilot CLI state separately, then add
   one thin adapter at a time.
5. Document each observer's stability, permissions, and failure modes before it
   is listed as supported in the README.

## Testing

- Unit tests for checkpoint load/save, duplicate suppression, and event ordering.
- E2E test: run `agit observe --once` over a fixture directory and assert it
  records the expected session steps.
- Resume test: run observer once, append new fixture events, run again, and
  assert only new events are recorded.
- Privacy test: observer output obeys metadata-only and redacted capture modes.

## Risks and tradeoffs

- Polling files is less precise than first-party lifecycle hooks. The observer
  model must tolerate missing intermediate state and mark low-confidence events.
- Agent internals may change without notice. Experimental adapters should fail
  closed and report clear diagnostics.
- Long-running observers create operational questions around startup, logs, and
  resource use. Keeping them explicit avoids surprising users.

## Consequences

- Pi and Copilot-style integrations get a deliberate architecture rather than
  hook-shaped workarounds.
- The recorder remains the single persistence path for all capture sources.
- Users retain local control over when background observation is active.

# ADR 024: Hook event identity and workspace-root resolution

**Status:** Accepted
**Date:** 2026-05-25

## Context

The hook adapters validate the incoming payload's `cwd`, but they do not use it
when opening the recorder. Each adapter calls `Recorder.open(io,
std.Io.Dir.cwd(), gpa)`, so capture depends on the process working directory
chosen by the agent runtime rather than the repository path carried in the hook
payload.

The same adapters also pass an empty string as `turn_id`:

- `src/hook/adapters/claude.zig`
- `src/hook/adapters/claude.zig`
- `src/hook/adapters/codex.zig`
- `src/hook/adapters/gemini.zig`

The recorder treats `(origin, session_id, turn_id)` as the idempotency key. A
stable empty turn id means a second finalized turn in the same agent session can
look like a duplicate. Since `recordAssistantAndFinalize` consumes staging
before the idempotency guard, this can drop later staged messages and tool calls.

These are capture-fidelity issues, not just UX issues. They affect what history
exists in the store.

## Decision

Introduce a normalized hook-event layer that owns workspace anchoring and turn
identity before events reach `Recorder`.

1. **Use payload `cwd` as the recording anchor.** Hook adapters must open the
   directory named by `cwd` and resolve the nearest `.agit/` from there. The
   process cwd is only a fallback for legacy or malformed payloads, and that
   fallback is logged.
2. **Define `NormalizedEvent`.** Add a shared type under `src/hook/` carrying:
   `origin`, `session_id`, `turn_id`, `workspace_cwd`, `event_name`,
   `source_event_id`, and the normalized message/tool/assistant payload.
3. **Derive non-empty turn ids.** Prefer an agent-provided turn/conversation
   event id when available. If none is available, maintain a session-scoped
   pending-turn state file under `.agit/tmp/turns/`:
   - user-prompt events start a new monotonic turn,
   - tool events attach to the active turn,
   - assistant/finalize events consume the active turn.
4. **Make ordering explicit.** The pending-turn state stores the last committed
   sequence number so concurrent hooks cannot reuse a turn id after finalize.
   Updates use the existing lock helper.
5. **Surface ambiguity.** If a tool or assistant event arrives without an active
   turn, record it under a generated recovery turn id and log a structured
   diagnostic rather than dropping it.

## Plan

1. Add `src/hook/event.zig` with `NormalizedEvent`, cwd resolution, and turn-id
   derivation helpers.
2. Refactor each hook adapter to produce `NormalizedEvent` and pass its
   `workspace_cwd` and `turn_id` to the recorder.
3. Extend recorder tests to cover two finalized turns in the same
   `(origin, session_id)`.
4. Add e2e tests where hook process cwd differs from payload `cwd`.
5. Update hook diagnostics so generated recovery turn ids are visible in
   `.agit/log/hook-error.log`.

## Testing

- Unit tests for turn-id derivation: agent-provided id, monotonic fallback,
  missing active-turn recovery, and concurrent event locking.
- E2E test: record two user/tool/assistant cycles with the same session id and
  assert `agit log` shows two distinct steps.
- E2E test: run a hook from a child or sibling directory while payload `cwd`
  points at the repository and assert the repository's `.agit/` receives the
  step.
- Regression test: second finalize with the same explicit turn id remains
  idempotent and does not create a duplicate step.

## Risks and tradeoffs

- Agent payload fields are not perfectly stable. The fallback counter keeps
  capture working, but exact turn ids may differ between agents until each
  adapter learns richer metadata.
- Maintaining pending-turn state adds another small mutable file. It must use
  the same durability and lock discipline as staging files.
- Recovery turn ids preserve data but may produce less elegant timelines. That
  is preferable to silent loss.

## Consequences

- Repeated turns in one agent session become representable.
- Hook capture follows the workspace reported by the agent instead of an
  incidental process cwd.
- Later adapter deduplication (ADR 017), historical search (ADR 022), export
  (ADR 027), and observer integrations (ADR 028) get a shared event contract
  instead of each re-solving identity.

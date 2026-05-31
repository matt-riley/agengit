# ADR 039: Replay is a non-goal

**Status:** Implemented
**Date:** 2026-05-31

## Context

"Replay / re-run a recorded session" is an obvious feature ask for an
agent-history tool, and it was floated while scoping the definitive agentic
shape. Replay means `agit` would take a recorded sequence and re-drive an agent
through it — which requires `agit` to own and launch the agent process and
integrate with each agent's *invocation* API, not just its lifecycle hooks.

That is the opposite of `agit`'s identity. `agit` is a passive recorder whose
hooks are fail-open precisely because it never controls the agent. Becoming an
agent *driver* would double the integration surface (capture *and* invocation)
per agent, pull in process orchestration and non-determinism, and break the
invariant that justifies the whole hook-safety model.

## Decision

Replay is an explicit **non-goal**. `agit` records agent activity; it does not
re-execute agents. The genuine user need behind "replay" — getting back to the
workspace state before an agent went wrong — is already met by `agit restore`
(ADR 034), with `agit diff`/`show` to inspect the prior trail. Users re-run their
agent themselves; `agit` makes the starting state and history available.

## Consequences

- `agit` never needs an agent-invocation integration, keeping per-agent work to
  capture adapters only.
- Requests for "replay" are redirected to `restore` + manual re-run; if a real
  replay-adjacent need emerges, it must be met without `agit` driving the agent.
- The fail-open, never-controls-the-agent invariant stays intact.

## Implementation Notes

- CLI scope remains unchanged: `agit` ships `recall` (read-only retrieval) and
  `restore` (workspace state rewind), with no `replay` command.
- Operator guidance is to inspect with `status`/`timeline`/`show`/`diff`,
  restore to a known good point, then re-run the agent manually.

# ADR 038: Recall — agent-readable institutional memory

**Status:** Implemented
**Date:** 2026-05-31

## Context

Until now `agit` has been a one-directional flight recorder: agents write
history through hooks, and only humans (or CI) read it back through
`status`, `timeline`, `log`, `show`, `diff`, `grep`, `blame`, and `stats`.
Earlier roadmap framing explicitly held that "capture should be helpful, not
bossy" and that hooks must never be required to feed or shape the agent.

A recorder nothing reads back is a diary. The strongest claim to being a
*definitive agentic* system — something git has no analogue for — is closing the
loop: letting an agent consult its own and prior agents' recorded history
*mid-task*, so it can avoid repeating an approach that already failed on a file.
This changes the original one-way posture, so it needs a recorded decision.

## Decision

Introduce **Recall**: an agent-initiated capability to query `agit`'s recorded
history during a task. The initial shape is deliberately incremental and
conservative:

1. **Pull, not push.** Recall is invoked by the agent; `agit` does not auto-inject
   memory into prompts. Push (augmenting `UserPromptSubmit`) is a later, explicit
   opt-in, not the default, because auto-injection is a context-pollution and
   trust escalation.
2. **CLI transport.** Recall ships as `agit recall <args> --json`, reusing the
   existing `cli-json-v1` envelope and the CLI/golden/e2e harness. Agents discover
   it via the repo's agent instruction files (CLAUDE.md / AGENTS.md / GEMINI.md).
   `agit` stays strictly one-shot-process; no long-lived MCP server for now.
3. **Per-repo scope first.** Recall reads only this repo's `.agit/` store.
   Cross-repo federated memory is a later opt-in with its own privacy gating,
   because it would break the local-store invariant and create a cross-project
   leak surface.
4. **Lexical + structured ranking.** Results are ranked by concrete, explainable
   signals — file path (snapshots + blame), **Outcome**, recency, and FTS5
   keyword match (ADR 022) — not embeddings. Semantic search remains an explicit
   opt-in for much later; bundling a model or calling a network embedding API
   would violate the small-binary and no-hidden-network-calls values.
5. **Outcome substrate.** Recall depends on knowing whether a Step succeeded or
   failed. A Step gains a first-class **Outcome** derived from structured tool
   status where the agent payload exposes it, with a heuristic classifier
   (exit-code / error / test-summary signals over the raw tool result text) as a
   coverage fallback. Git/CI "did it survive" correlation (building on ADR 033) is
   a later enrichment.
6. **Model and cost metadata are deferred.** The initial Recall slice ships
   path/query retrieval plus first-class **Outcome**. Optional model-identifier
   and token/cost fields remain compatible future extensions when the agent
   payloads expose them, following the same additive evolution pattern that
   already grew `messages` and `tool_calls`.
7. **Companion non-goal: replay stays out.** Recall is read-only retrieval.
   Re-driving an agent through a past session is explicitly out of scope and is
   captured separately in ADR 039.

## Considered options

- **Git-verb parity instead (branch/merge/rebase/revert/bisect/tag over agent
  history).** Rejected as the anchor: it copies git rather than leaning into what
  is uniquely agentic, and the project chose agent-native capabilities.
- **Push-first (auto-inject memory into every prompt).** Rejected as the default:
  higher leverage but a context-pollution footgun and trust escalation; deferred
  to explicit opt-in.
- **MCP server transport.** Deferred: nicer discoverability but adds a server
  lifecycle and JSON-RPC surface before retrieval quality is even proven; the
  same engine can be wrapped as MCP later without duplicating logic.
- **Semantic/embedding ranking.** Deferred: trades the network-free, small-binary
  identity for recall on a query shape Recall does not center on.

## Plan

1. Extend the step schema with optional `outcome`, keeping old objects valid.
   Model/token/cost metadata remains a follow-on extension.
2. Add best-effort outcome derivation during finalize, preferring structured
   tool status and falling back to bounded heuristics over tool result text.
3. Index the new retrieval signals in SQLite so `agit reindex` can backfill
   them from existing objects without changing refs or canonical object bytes.
4. Implement `agit recall` with a JSON-first output shape under the existing
   `cli-json-v1` envelope, then add a concise human-readable rendering.
5. Support an initial query surface centered on concrete investigation tasks:
   file/path filters, session/origin filters, outcome filters, recency, and
   free-text terms routed through existing FTS5 support.
6. Reuse existing snapshot/blame data to rank "what happened on this path?"
   style queries without introducing a new storage backend.
7. Update agent instruction files and README examples so agents can discover
   Recall as an explicit tool, not an ambient side channel.

## Testing

- Unit test: outcome derivation prefers structured exit status when available
  and falls back to heuristics only when structure is absent.
- Unit test: reindex backfills outcome metadata for pre-Recall steps without
  mutating canonical object hashes.
- E2E test: `agit recall --json --path <file>` returns failed same-path steps
  ahead of unrelated ones for a known fixture history.
- E2E test: origin/session/outcome filters combine correctly and degrade
  cleanly when older steps lack the new metadata.
- Golden test: human-readable Recall output stays concise and evidence-oriented.
- Golden test: `--json` output uses the shared `cli-json-v1` envelope with
  stable machine-readable fields.

## Risks and tradeoffs

- Outcome inference can be wrong. That is acceptable only if the field is
  explicitly best-effort, explainable, and upgradeable by `reindex`.
- Retrieval can pollute context if it returns too much text. The command should
  favor compact evidence snippets and stable ranking over bulk transcript dumps.
- Adding agent-readable retrieval changes the trust boundary. Keeping Recall as
  an explicit pull command preserves user visibility and avoids surprise prompt
  shaping.
- Once agents can query memory, users may ask for auto-injection by default.
  This ADR deliberately does not grant that; push remains a separate decision.

## Consequences

- `agit` stops being strictly write-and-inspect-only; agents become first-class
  readers of recorded history through an explicit CLI path.
- This narrows the old "capture should be helpful, not bossy" posture for the
  pull path only; push remains forbidden by default.
- `Step` schema evolves with optional `outcome`; existing objects parse
  unchanged and `agit reindex` backfills derived rows.
- A new `agit recall` command and its ranking logic become part of the supported
  CLI and must carry golden/e2e coverage.
- ADR 039 becomes the guardrail beside this decision: memory retrieval is in,
  agent replay is out.

# ADR 042: Per-step model attribution

**Status:** Accepted
**Date:** 2026-06-20

## Context

`Step` (`src/store/object.zig:61-76`) records `origin` — which agent CLI ran
(`claude`, `codex`, `gemini`, `copilot`, `pi`) — but never which underlying
model answered the turn. `agit blame` and `agit log` can say "Claude Code
touched this line," not "claude-sonnet-4-6 touched this line." For a fleet
running multiple models through the same CLI (or CLIs with per-turn model
switching), that's a real gap in attribution.

None of the five integrated CLIs expose model on their main OpenTelemetry
surface in a way that's easier to consume than the hooks themselves — OTel is
a separate, opt-in export channel, not the hook stdin payload `agit` parses.
So this ADR is scoped to what's reachable from the **hook payload / extension
API agit already has wired up**, not OTel.

Research findings per CLI, verified against primary docs where reachable:

- **Codex CLI:** OpenAI's official Codex hooks documentation lists `model` as
  a common input field on command hooks: a Codex-specific extension containing
  the active model slug. `src/hook/adapters/codex.zig` can read it from payloads
  it already receives, with no new hook subscription.
- **Claude Code:** confirmed via `code.claude.com/docs/en/hooks` — `model` is
  delivered **only** on the `SessionStart` hook, and even there "is not
  guaranteed to be present." `agit`'s Claude adapter (`src/hook/adapters/claude.zig`)
  does not currently subscribe to `SessionStart` at all (it handles
  `UserPromptSubmit` and `PostToolBatch`). Capturing model means adding a new
  hook subscription, not just reading an existing field. The docs also note
  the model shown at `SessionStart` does not update when the user runs
  `/model` mid-session, so it is a session-level hint, not a true per-turn
  value.
- **Gemini CLI:** confirmed via `google-gemini/gemini-cli`'s
  `docs/hooks/reference.md` — `model` exists only nested as `llm_request.model`
  on `BeforeModel` / `AfterModel` / `BeforeToolSelection` hooks. The two hooks
  `agit`'s Gemini adapter (`src/hook/adapters/gemini.zig`) currently subscribes
  to (`AfterAgent`, `AfterTool`) do not carry it. Capturing model here also
  means adding a new hook subscription and parsing a nested field instead of a
  top-level one.

Out of scope for this ADR (left for follow-up investigation, not designed
here):

- **Copilot CLI:** confirmed via the official `copilot-sdk` `docs/hooks/post-tool-use.md`
  that `onPostToolUse` input is `{timestamp, workingDirectory, toolName,
  toolArgs, toolResult}` — no model field. `onUserPromptSubmitted`'s only
  documented field is `prompt`. Copilot CLI also has no native OpenTelemetry
  support yet (tracked upstream, unresolved). No known path to model
  attribution today.
- **Pi:** the basic events `agit`'s generated extension (`src/cli/pi_extension.zig`)
  forwards (`input`, `tool_execution_end`, `agent_end`) carry no model field,
  but third-party OTel extensions for Pi (e.g. `pi-otel`) report a
  session-level `llm.model` attribute, implying Pi's extension/session API
  exposes the active model to extensions that read it directly off session
  state rather than off the event payload. Unverified — the Pi extension API
  reference page was unreachable during this research pass.

## Decision

Add an optional `model: ?[]const u8 = null` field to `Step`
(`src/store/object.zig`), populated only where a CLI's *hook payload* exposes
it without requiring speculative reverse-engineering:

1. **Codex** — read `model` directly from the existing `UserPromptSubmit` /
   `PostToolUse` / `Stop` payloads in `src/hook/adapters/codex.zig`. Lowest
   risk: no new hook subscription, no settings/install changes.
2. **Claude Code** — add a `SessionStart` subscription to the Claude hook
   adapter and to the generated `~/.claude/settings.json` hook entries
   (`src/cli/init_plan.zig` / wherever Claude's hook config is written).
   Treat the captured model as a session-level attribute (attach it to the
   `Step`s for that session, not a verified per-turn value), and treat absence
   as expected/normal rather than a parse error, per the docs' own caveat.
3. **Gemini CLI** — add a `BeforeModel` (or `AfterModel`) subscription to the
   Gemini hook adapter and Gemini's hook settings, and parse
   `llm_request.model` instead of a top-level field.
4. Render the new field wherever `origin` is already rendered: `agit blame`
   (human + `--json`), `agit log`, `agit show`. Absence of `model` (Copilot,
   Pi, or any CLI/version that doesn't supply it) must render exactly like
   today — no blank columns, no errors.
5. `agit reindex` must treat `model` as optional historical metadata: steps
   written before this change have no model and must remain valid.

## Implementation

Implemented in the accepted change:

1. Add `model` to `Step`, defaulting to `null`, with a unit test asserting old
   step JSON (no `model` key) parses unchanged.
2. Add index schema version 11 with nullable `steps.model`, and preserve it
   through normal finalize, CAS replay, and `agit reindex`.
3. Capture Codex `model` from existing `UserPromptSubmit` / `PostToolUse` /
   `Stop` payloads.
4. Capture Claude `SessionStart` model as a session-level hint and attach it to
   later steps in that session.
5. Capture Gemini `BeforeModel.llm_request.model` as turn-scoped metadata.
6. Render model in `agit blame`, `agit log`, and `agit show` human/JSON output
   only when present.
7. Document the per-CLI caveats in README so users don't expect per-turn
   precision where the upstream CLI doesn't provide it.

## Risks and tradeoffs

- Codex's `model` field is documented by OpenAI as a Codex-specific hook input
  extension, but older Codex versions or disabled hook features may omit it.
- Claude Code's model value is session-scoped and explicitly not guaranteed,
  so it's a best-effort hint, not a reliable per-turn fact — must be
  documented as such to avoid misleading blame output.
- Adding new hook subscriptions (Claude `SessionStart`, Gemini `BeforeModel`)
  touches install/doctor/uninstall surfaces for those two CLIs, not just
  parsing — larger blast radius than the Codex change.
- Out-of-scope CLIs (Copilot, Pi) mean `model` will be inconsistently
  available across the fleet indefinitely; rendering must treat that as the
  normal case, not a degraded one.

## Consequences

- `agit blame`/`log`/`show` can report model identity for Codex, Claude Code,
  and Gemini sessions once implemented, closing part of the attribution gap
  this ADR was written to address.
- Copilot and Pi remain origin-only (no model) until a follow-up ADR resolves
  the open questions noted above.
- `Step`'s schema gains one more optional, backward-compatible field,
  consistent with how `outcome`/`git_commit`/`git_branch`/`git_dirty` were
  added previously.

# AgenGit

Domain language for `agit`, a local recorder of AI-agent coding activity that
is evolving from a read-only flight recorder into an agent-readable
institutional memory. This glossary captures terms meaningful to the agent-history
domain, not implementation utilities.

## Language

**Step**:
One agent turn — a prompt, zero or more tool calls, an assistant response, and the workspace snapshot taken at finalize — stored as one content-addressed object.

**Session**:
A continuous agent conversation, identified by a session id scoped to an origin, whose latest Step is tracked by a ref.

**Origin**:
The agent that produced an activity stream (e.g. Claude Code, Codex CLI, Gemini CLI).
_Avoid_: agent type, source (when referring specifically to the producing agent)

**Snapshot**:
The filtered workspace tree captured at a Step, recorded as a content-addressed tree object.

**Outcome**:
Whether a Step's work succeeded or failed — captured structurally when the agent exposes it and inferred heuristically otherwise — as distinct from the raw tool result text.
_Avoid_: result (a tool's raw text payload is the Tool Result, not the Outcome)

**Recall**:
The agent-initiated (pull) capability by which an agent queries agit's recorded history mid-task to consult prior Steps before acting.
_Avoid_: memory injection (that is the future push variant), search (Recall is outcome-aware, not just lexical)

**Observer**:
An experimental capture path that polls an external source for agent events instead of receiving lifecycle hooks.

## Relationships

- An **Origin** produces one or more **Sessions**
- A **Session** is an ordered chain of **Steps** (each Step points at its parent)
- A **Step** captures exactly one **Snapshot** and zero or more Tool Results
- A **Step** has one **Outcome** (success or failure), derived from its Tool Results
- **Recall** reads past **Steps** (filtered by **Outcome** and path) to inform a new agent turn

## Example dialogue

> **Dev:** "When **Recall** answers 'what broke here last time', is it reading the tool result text?"
> **Domain expert:** "No — it reads the **Outcome**. The raw result text is just evidence; the **Outcome** is the success/failure judgement we derive from it. Recall ranks failed **Steps** for the same path so the agent avoids repeating them."

## Flagged ambiguities

- "result" was used to mean both a tool's raw text output and whether a Step worked — resolved: **Tool Result** is the raw text, **Outcome** is the derived success/failure judgement; they are distinct.
- "memory" was used to mean both pull (**Recall**) and a future auto-injection (push) mode — resolved: **Recall** is strictly the agent-initiated pull capability.

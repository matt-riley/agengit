# AgenGit

Domain language for `agit`, a local recorder of AI-agent coding activity that is evolving from a read-only flight recorder into an agent-readable institutional memory. This glossary captures terms meaningful to the agent-history domain, not implementation utilities.

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

**Session Evaluation**:
A judgment about a recorded agent session based only on evidence already captured by AgenGit.
_Avoid_: eval result, grade

**Captured Evidence**:
Session data already recorded by AgenGit, including messages, tool calls, timestamps, step relationships, and workspace snapshots.
_Avoid_: ground truth, proof

**Outcome Context**:
User-held information about code understanding, acceptance, test results, production behavior, or other results not reliably inferable from captured evidence alone.
_Avoid_: hidden signal, real score

**Evaluation Report**:
A human-readable or JSON summary of session-quality signals and prompt patterns derived from captured session history.
_Avoid_: training data, outcome label store

**Evaluation Dimension**:
A named quality signal within a session evaluation, such as goal clarity, tool efficiency, failure recovery, or completion signal.
_Avoid_: subscore, metric bucket

**Evaluation Scope**:
The set of recorded activity included in an evaluation report, such as one session, a date window, or activity associated with a git commit range.
_Avoid_: target, query

**Commit Evaluation**:
An evaluation report whose scope is inferred from recorded activity associated with a git commit or git commit range.
_Avoid_: commit score, git grade

**Follow-up Signal**:
Captured evidence after an evaluation scope that may confirm, weaken, or contradict the apparent quality of the scoped activity.
_Avoid_: hindsight, later truth

**Pattern Association**:
A non-causal relationship between phrases or behaviors in captured evidence and higher- or lower-rated session evaluations.
_Avoid_: success predictor, outcome correlation

**Good Session**:
A recorded agent session whose captured evidence suggests useful, goal-directed progress toward the user's intent.
_Avoid_: successful run, passing session

**Bad Session**:
A recorded agent session whose captured evidence suggests failure, churn, misleading output, or unresolved work relative to the user's intent.
_Avoid_: failed run, broken session

## Relationships

- An **Origin** produces one or more **Sessions**
- A **Session** is an ordered chain of **Steps** (each Step points at its parent)
- A **Step** captures exactly one **Snapshot** and zero or more Tool Results
- A **Step** has one **Outcome** (success or failure), derived from its Tool Results
- **Recall** reads past **Steps** (filtered by **Outcome** and path) to inform a new agent turn
- A **Session Evaluation** uses **Captured Evidence** but does not ingest or store **Outcome Context**.
- An **Evaluation Report** exposes **Session Evaluation** signals for humans and agents.
- An **Evaluation Report** contains one or more **Evaluation Dimensions** plus an overall classification.
- An **Evaluation Scope** may contain more than one recorded session.
- A **Commit Evaluation** is an **Evaluation Report** with a git-derived **Evaluation Scope**.
- A **Follow-up Signal** can change confidence in a **Session Evaluation** or **Commit Evaluation** without changing the original captured activity.
- A **Pattern Association** compares captured phrases or behaviors against AgenGit's own evidence-based classifications, not external production outcomes.
- A **Good Session** and a **Bad Session** are evaluation outcomes for a recorded agent session.
- **Captured Evidence** can suggest quality but does not prove production success.

## Example dialogue

> **Dev:** "When **Recall** answers 'what broke here last time', is it reading the tool result text?"
> **Domain expert:** "No — it reads the **Outcome**. The raw result text is just evidence; the **Outcome** is the success/failure judgement we derive from it. Recall ranks failed **Steps** for the same path so the agent avoids repeating them."

> **Dev:** "Can `agit eval` tell me whether this agent session fixed the production issue?"
> **Domain expert:** "No — from **Captured Evidence** alone, it can say whether the session looked productive or risky, then you compare that with your **Outcome Context**."

## Flagged ambiguities

- "result" was used to mean both a tool's raw text output and whether a Step worked — resolved: **Tool Result** is the raw text, **Outcome** is the derived success/failure judgement; they are distinct.
- "memory" was used to mean both pull (**Recall**) and a future auto-injection (push) mode — resolved: **Recall** is strictly the agent-initiated pull capability.
- "good" and "bad" were resolved as session-quality judgments, not absolute proof of code correctness or production impact.
- "outcome" was resolved as user-held context outside `agit eval`, not data that the command records or uses as an input label.
- "commit evaluation" was resolved as an inferred association between captured agent activity and Git history, not exact commit provenance stored in session objects.
- "later failure" was resolved as a **Follow-up Signal** that should affect confidence in an earlier evaluation scope.
- "better/worse results" was resolved as **Pattern Association** against evidence-based evaluation ratings, not causal proof of real-world outcomes.

# ADR 033: Evidence-based session evaluation

**Status:** Accepted
**Date:** 2026-06-16

## Context

`agit` records AI-agent execution history, but users also need to understand
whether those sessions look productive, risky, repetitive, or likely to need
follow-up. A future `agit eval` command should help answer questions such as:

- Did this session look like a good or bad agent run?
- Which dimensions made it look good, mixed, bad, or unknown?
- Which prompt phrases or workflow patterns are associated with higher- or
  lower-rated captured sessions?
- What did the agent activity around a commit or commit range look like?
- Did later captured prompts contradict an earlier session or commit that looked
  successful in isolation?

The store does not currently record real-world outcomes such as user acceptance,
CI status, production health, or exact Git commit provenance for each step.
Those facts may be known to the user, but they are not reliable captured
evidence inside `.agit/`.

## Decision

Add an `agit eval` investigation command whose classifications are explicitly
evidence-based, not claims of real-world success.

1. **No outcome-label ingestion in v1.** `agit eval` reads only captured
   AgenGit history and repository Git metadata needed to infer commit windows.
   It does not ask the user for labels, store user outcome annotations, or train
   against production outcomes.
2. **Dimension-first reports.** Every report includes separate evaluation
   dimensions plus an overall classification. Initial dimensions are:
   `goal_clarity`, `execution_focus`, `failure_recovery`, `verification`,
   `completion_signal`, and `churn_risk`.
3. **Evidence-backed ratings.** Each dimension reports a rating, score,
   confidence, reasons, and raw signal counts. Ratings are derived from
   deterministic rules over messages, tool calls, step shape, and optional
   snapshot-diff metadata.
4. **Good and bad are scoped terms.** A good session is one whose captured
   evidence suggests useful, goal-directed progress. A bad session is one whose
   captured evidence suggests failure, churn, misleading output, or unresolved
   work. Neither label proves code correctness or production impact.
5. **JSON is first-class.** `--json` uses the repository-wide JSON envelope so
   agents can consume eval reports during loop sessions and adjust prompts or
   workflow behavior.
6. **Pattern recognition is non-causal.** Pattern reporting compares phrases and
   behaviors against `agit eval`'s own higher- and lower-rated captured sessions,
   not against external outcomes. Reports must use language such as
   "associated with higher-rated sessions" and include support/confidence.
7. **Deterministic dimensions, statistical patterns.** Built-in deterministic
   rule dictionaries drive the evaluation dimensions. Statistical phrase
   discovery is limited to the pattern section, where it can surface local
   prompt or workflow associations without changing the stable rubric.
8. **Commit and range evaluation are inferred.** Because current step objects do
   not store Git commit ids, `agit eval --commit <rev>` and
   `agit eval --range <a>..<b>` infer an evaluation scope from Git timestamps and
   changed-path overlap. Reports include association confidence and must not
   imply exact provenance.
9. **Lookahead follow-up signals qualify earlier scopes.** Scoped evaluations
   distinguish the in-scope assessment from later captured evidence. A bounded
   lookahead detects later prompts and tool results such as "workflow failed",
   "tests are still failing", "that did not work", "rollback", or "CI failed",
   and can downgrade or qualify the current assessment without rewriting the
   original in-scope result.
10. **Privacy controls apply.** Human and JSON output that includes snippets,
    phrases, or examples must respect display-time redaction controls from ADR
    026. Pattern examples should prefer session ids and step hashes over raw
    captured text.

## Initial command shape

```sh
agit eval [OPTIONS]
agit eval --session codex/session-abc
agit eval --commit HEAD
agit eval --range HEAD~3..HEAD
agit eval --since 2026-06-01 --until 2026-06-16
agit eval --json --commit HEAD~1 --lookahead 24h
agit eval --json --no-lookahead
```

Initial filters mirror existing investigation commands where possible:
`--origin`, `--session`, `--since`, `--until`, `--limit`, `--redacted`,
`--full`, and `--json`.

## Report model

The human report summarizes:

- selected evaluation scope and association confidence,
- overall classification: `good`, `mixed`, `bad`, or `unknown`,
- dimension ratings and concise reasons,
- follow-up signals when lookahead is enabled,
- pattern associations with support and confidence.

The JSON report includes the same data in the standard envelope:

```json
{
  "schema_version": "cli-json-v1",
  "command": "eval",
  "data": {
    "scope": { "kind": "commit", "rev": "HEAD~1" },
    "association_confidence": "medium",
    "in_scope_assessment": {
      "classification": "good",
      "confidence": "medium",
      "dimensions": {
        "goal_clarity": {
          "rating": "good",
          "score": 82,
          "confidence": "medium",
          "reasons": ["Initial prompt names a concrete command and behavior."],
          "signals": { "concrete_terms": 6, "success_criteria_phrases": 2 }
        }
      }
    },
    "follow_up_assessment": {
      "classification_delta": "downgrade",
      "signals": [
        {
          "kind": "failure_report",
          "session_id": "codex/next-session",
          "step_hash": "abc123def456",
          "phrase": "workflow failed"
        }
      ]
    },
    "current_assessment": {
      "classification": "mixed",
      "confidence": "high"
    },
    "patterns": [
      {
        "phrase": "run tests",
        "source": "user_prompt",
        "association": "higher_rated_sessions",
        "dimension": "verification",
        "support": 14,
        "confidence": "medium"
      }
    ]
  }
}
```

## Plan

1. Add `src/store/eval.zig` with data types for ratings, dimensions,
   assessments, follow-up signals, and pattern associations.
2. Add index query helpers for evaluation scopes: session, date window, recent
   sessions, and text/tool rows needed for scoring.
3. Implement deterministic signal extraction:
   - goal clarity from early user/assistant messages,
   - execution focus from prompt terms versus tool names, arguments, and touched
     paths,
   - failure recovery from error terms and subsequent changed behavior,
   - verification from test/build/check commands and final-message alignment,
   - completion signal from final assistant summary content,
   - churn risk from step count, repeated commands, repeated failures, and
     file-change breadth.
4. Implement `src/cli/eval.zig` with human and JSON output.
5. Add built-in dictionaries for verification commands, failure terms, recovery
   terms, vague completion terms, and follow-up failure phrases.
6. Add statistical phrase discovery for the `patterns` section with minimum
   support thresholds and stopword filtering.
7. Implement Git-scope inference for `--commit` and `--range` by shelling out to
   `git` or adding a narrow Git helper module, then combine timestamp windows
   with changed-path overlap for association confidence.
8. Implement lookahead scanning with defaults such as `--lookahead 24h` and
   `--no-lookahead`.
9. Wire the command into `src/main.zig`, `src/cli/specs.zig`,
   `src/cli/registry.zig`, generated help/completions, README generation, and
   JSON format docs.

## Testing

- Unit tests for each dimension scorer with synthetic messages/tool calls.
- Unit tests for phrase extraction, stopword filtering, minimum support, and
  higher/lower association calculations.
- Unit tests for follow-up phrase detection and classification deltas.
- E2E test: seed a clearly good session and assert `agit eval --json
  --session ...` reports good goal clarity and verification.
- E2E test: seed a repeated failing-command session and assert bad or mixed
  failure recovery plus churn risk.
- E2E test: seed a later prompt saying "the workflow failed" and assert
  lookahead downgrades or qualifies an earlier scoped report.
- E2E test: evaluate a Git commit/range in a temporary repo and assert the
  report includes association confidence rather than exact provenance.
- Golden tests for human output and JSON envelope shape.

## Risks and tradeoffs

- Evidence-based classification can be mistaken. The report must show reasons,
  signal counts, and confidence so users and agents can decide how much to trust
  it.
- Deterministic rules are less nuanced than an LLM evaluator, but they are
  explainable, cheap, stable for `--json`, and safe for offline local use.
- Commit/range eval can only infer association until step objects record Git
  commit metadata. Confidence labels are required to avoid misleading users.
- Pattern associations may tempt users to infer causality. Report language and
  JSON field names must avoid causal claims.

## Consequences

- `agit` gains a quality-oriented investigation workflow without expanding the
  capture store into an outcome-label system.
- Agents can consume `agit eval --json` during loop sessions to adjust prompts,
  validation behavior, and recovery strategy.
- Future versions can add exact Git metadata capture or optional external
  evaluators without changing the v1 boundary that captured evidence is not
  ground truth.

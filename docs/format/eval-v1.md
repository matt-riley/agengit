# Eval v1

`agit eval` produces structured session-quality ratings.  When `--json` mode is
used, the `eval_hash` field in the JSON envelope points to the content-addressed
eval object persisted under `.agit/objects/`.

## Eval object

An `eval` object is a content-addressed JSON object (BLAKE3, stored under
`.agit/objects/`) that captures a session quality assessment at a point in time:

```json
{
  "type": "eval",
  "assessment": {
    "classification": "good",
    "confidence": "high",
    "dimensions": {
      "goal_clarity": {
        "rating": "good",
        "score": 90,
        "confidence": "medium",
        "reasons": ["Initial prompt includes concrete task terms or success criteria."],
        "signals": { "concrete_terms": 6, "success_criteria_phrases": 0, "tool_calls": 3, "related_tool_calls": 2, "error_results": 2, "recovered_errors": 0, "repeated_failures": 1, "verification_commands": 1, "final_summary_terms": 2, "repeated_commands": 0, "steps": 2 }
      },
      "execution_focus": { "rating": "good", "score": 66, "confidence": "medium", "reasons": ["Tool activity overlaps with terms from the initial prompt."], "signals": { "concrete_terms": 0, "success_criteria_phrases": 0, "tool_calls": 0, "related_tool_calls": 0, "error_results": 0, "recovered_errors": 0, "repeated_failures": 0, "verification_commands": 0, "final_summary_terms": 0, "repeated_commands": 0, "steps": 0 } },
      "failure_recovery": { "rating": "bad", "score": 15, "confidence": "high", "reasons": ["The session repeated failure output without captured recovery."], "signals": { "concrete_terms": 0, "success_criteria_phrases": 0, "tool_calls": 0, "related_tool_calls": 0, "error_results": 0, "recovered_errors": 0, "repeated_failures": 1, "verification_commands": 0, "final_summary_terms": 0, "repeated_commands": 0, "steps": 0 } },
      "verification": { "rating": "good", "score": 85, "confidence": "high", "reasons": ["Captured tool calls include a test, build, or check command."], "signals": { "concrete_terms": 0, "success_criteria_phrases": 0, "tool_calls": 0, "related_tool_calls": 0, "error_results": 0, "recovered_errors": 0, "repeated_failures": 0, "verification_commands": 1, "final_summary_terms": 0, "repeated_commands": 0, "steps": 0 } },
      "completion_signal": { "rating": "good", "score": 80, "confidence": "medium", "reasons": ["Final assistant message mentions change or verification signals."], "signals": { "concrete_terms": 0, "success_criteria_phrases": 0, "tool_calls": 0, "related_tool_calls": 0, "error_results": 0, "recovered_errors": 0, "repeated_failures": 0, "verification_commands": 0, "final_summary_terms": 2, "repeated_commands": 0, "steps": 0 } },
      "churn_risk": { "rating": "mixed", "score": 55, "confidence": "medium", "reasons": ["Some repeated activity suggests mild churn risk."], "signals": { "concrete_terms": 0, "success_criteria_phrases": 0, "tool_calls": 0, "related_tool_calls": 0, "error_results": 0, "recovered_errors": 0, "repeated_failures": 0, "verification_commands": 0, "final_summary_terms": 0, "repeated_commands": 1, "steps": 2 } }
    }
  },
  "evaluation_scope": {
    "kind": "session",
    "origin": "codex",
    "session_id": "session-abc"
  },
  "evaluated_at": 1700000000000,
  "agit_version": "1.22.3",
  "captured_evidence_hash": "<64-hex BLAKE3 of sorted scope step hashes>"
}
```

### Fields

- `type` — always `"eval"`.
- `assessment` — the serialized `Assessment` struct from the eval engine
  (see ADR 033). Contains `classification`, `confidence`, and per-dimension
  breakdowns with signals.
- `evaluation_scope` — an object identifying what was evaluated.
  - `kind` — one of `"session"`, `"commit"`, `"range"`, `"window"`.
  - For `"session"`: `origin` and `session_id` are present.
  - For `"commit"`: `origin` (optional) and `rev` are present.
  - For `"range"`: `origin` (optional) and `range` are present.
  - For `"window"`: `origin` (optional), `since` and `until` (optional).
- `evaluated_at` — Unix epoch milliseconds when the evaluation was computed.
- `agit_version` — the agit version string that produced this eval.
- `captured_evidence_hash` — BLAKE3 over the sorted list of step hashes that
  were in scope at evaluation time.  Deterministic: re-running on the same
  scope produces the same hash and therefore the same eval object hash.

## Immutability and staleness

Eval objects are content-addressed and immutable.  If the evidence (step set)
has not changed, re-evaluating produces an identical eval object and no new
object is written.  If evidence has changed (new steps, deleted steps), a new
eval object with a different `captured_evidence_hash` is produced.

When multiple eval objects exist for the same scope, the one with the latest
`evaluated_at` is authoritative.

## Rebuild on reindex

`agit reindex` walks `objects/` and inserts `eval` rows into the
`evaluations` table from the parsed eval objects.  Because `captured_evidence_hash`
is deterministic, the reconstructed rows match the original ones exactly.

## Listing evaluations: `--list`

`agit eval --list --json` lists all stored evaluation objects without
computing a new one:

```sh
agit eval --json --list
```

The JSON envelope includes an `evals` array with eval summary rows:

```json
{
  "schema_version": "cli-json-v1",
  "command": "eval",
  "data": {
    "evals": [
      {
        "eval_hash": "<64-hex>",
        "scope_type": "session",
        "scope_key": "codex/session-abc",
        "classification": "good",
        "captured_evidence_hash": "<64-hex>",
        "evaluated_at": 1700000000000
      }
    ]
  }
}
```

The `--list` flag requires `--json` and is mutually exclusive with evaluation
scope flags (`--session`, `--commit`, `--range`, `--since`, `--until`).

## Per-step signals: `--include-steps`

When `--include-steps` is passed, the JSON output includes a
`step_assessments` array with per-step quality signal counts:

```json
{
  "step_assessments": [
    {
      "hash": "<64-hex>",
      "turn_id": "turn-1",
      "timestamp": 1700000000000,
      "signals": {
        "concrete_terms": 6,
        "success_criteria_phrases": 1,
        "tool_calls": 3,
        "related_tool_calls": 2,
        "error_results": 0,
        "recovered_errors": 0,
        "repeated_failures": 0,
        "verification_commands": 1,
        "final_summary_terms": 2,
        "repeated_commands": 0,
        "steps": 1
      }
    }
  ]
}
```

Each entry contains the step's hash, turn_id, timestamp, and the
`SignalCounts` struct with raw quality signals for that step in isolation
(without cross-step state like error recovery chains).

The `step_assessments` array is always present in the JSON output (empty
when `--include-steps` is not set). Consumers should check the array length
to determine if per-step data was requested.

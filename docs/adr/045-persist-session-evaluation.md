# ADR 045: Persist Session Evaluation Reports as Content-Addressed Objects

**Status:** accepted
**Date:** 2025-06-21
**Context:** `agit eval` currently computes session quality ratings on-the-fly
and emits them to stdout or `--json`.  There is no persistent record of
the evaluation — every invocation re-computes from scratch.

## Decision

Persist each evaluation run as a content-addressed `eval` object under
`.agit/objects/`.  The object includes the full assessment, scope
identifier, and a `captured_evidence_hash` (BLAKE3 over the sorted step
hashes in scope).  The evaluation is recorded in a rebuildable `evaluations`
table in the SQLite index.

## Object format

Defined in `docs/format/eval-v1.md`.  Key properties:

- **`captured_evidence_hash`** — makes the eval deterministic and
  content-addressable.  Running `agit eval` twice on the same scope
  produces the same hash → no duplicate object.
- **Immutability** — once written, an eval object never changes.  If
  the evidence changes (new steps), a new object is produced.
- **`evaluated_at`** — when multiple evals exist for the same scope,
  the latest `evaluated_at` wins.

## Staleness policy

Eval objects are never mutated.  Re-running `agit eval` on the same
scope with the same evidence produces an identical object (same BLAKE3
hash) — `object.writeDetailed` is idempotent and the write is a no-op.

If evidence changes (steps added, removed), a new eval object is written
with a different `captured_evidence_hash`.  The `evaluations` table
may accumulate multiple rows for the same scope; the one with the
largest `evaluated_at` is the latest and authoritative.

## Reindex

`agit reindex` reconstructs the `evaluations` table from `objects/` by
parsing every object with `"type":"eval"`.  The reconstructed rows are
identical to the originals because the eval object itself is the source
of truth.

## Index schema (migration 13)

```sql
create table evaluations (
    hash                      text primary key,
    scope_type                text not null,
    scope_key                 text not null,
    classification            text not null,
    captured_evidence_hash    text not null,
    evaluated_at              integer not null
);
create index evaluations_scope_latest on evaluations(scope_type, scope_key, evaluated_at desc);
```

- `hash` — the eval object's BLAKE3 hex hash.
- `scope_type` — `session`, `commit`, `range`, or `window`.
- `scope_key` — a human-readable identifier for the scope
  (e.g. `"codex/session-abc"`).
- `classification` — `good`, `mixed`, `bad`, or `unknown`.
- `captured_evidence_hash` — 64-char hex of the BLAKE3 evidence hash.
- `evaluated_at` — Unix epoch ms when the eval was computed.

## CLI impact

- `agit eval --json` gains an `eval_hash` field in the data envelope.
- `agit recall --judged <bad|good|mixed>` filters to sessions whose
  latest evaluation has the given classification.
- `agit recall --json` gains a `judged` filter in the envelope.

## References

- ADR 033 — Evidence-Based Session Evaluation (eval engine)
- ADR 038 — Recall: Agent-Readable Memory (recall command)
- `docs/format/eval-v1.md` — eval object format

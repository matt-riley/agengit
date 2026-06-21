# ADR 043: JSONL session log observer source

**Status:** Proposed (experimental)
**Date:** 2026-06-21

## Context

ADR 028 left the observer framework open for "genuinely hookless agents
(file/log/IPC-only state)." Until now the registry shipped a single source,
`fixture`, which replays a synthetic JSON document. That proves the framework
but does not prove a real polling source over an append-only log.

The adjacent possible is disproportionate: a real polling source is one
`Source` implementation, not new infrastructure. This ADR records the first
concrete one.

## Decision

Ship `jsonl`, an experimental observer source that tails a JSONL agent
session log — one event per line — under `src/observer/sources/jsonl.zig`,
registered in `src/observer/sources/registry.zig`.

Input shape (one event per line, `--input <path>`):

```jsonl
{"session_id":"...","cwd":"...","role":"user","content":"..."}
{"session_id":"...","cwd":"...","role":"tool","tool_name":"...","args":"...","result":"..."}
{"session_id":"...","cwd":"...","role":"assistant","content":"..."}
```

`role` maps to `Record` variants and `EventKind`:

| role      | EventKind    | event_name (default) | record(s)              |
|-----------|--------------|----------------------|------------------------|
| `user`    | `user_prompt`| `UserPromptSubmit`  | `user_prompt` (content)|
| `tool`    | `tool_use`   | `PostToolUse`        | `tool_use` (name/args/result) |
| `assistant`| `assistant` | `Stop`               | `assistant` (content)  |

Unknown/extra fields are ignored (`ignore_unknown_fields = true`); an unknown
or missing required field yields `InvalidObserverEvent`.

### Watermark and instance identity

- `watermark` = the **1-based line number** of the event in the file. Line
  numbers are monotonic across appends to the same file, so the runner's
  `updateCheckpoint` resumes strictly past the last processed line.
- `instance_id` = the **Blake3 hex of the resolved absolute path** of the
  input file — not mtime, not content. The runner errors
  `ObserverCheckpointInstanceMismatch` if it changes between runs, so it must
  be stable for the same logical log.

### Resume semantics

On `--once`, the source reads the whole file (capped at 4 MiB, matching the
fixture safety cap), skips blank lines and any line number `<=` the stored
watermark, and emits the rest. There is deliberately **no
`ObserverWatermarkNotFound`** for a missing line: because line numbers are
positional, a stale watermark simply yields zero new events when nothing was
appended, and resumes at the next appended line otherwise. This is the
file-tail behavior the framework was designed for.

## Trade-offs and risks

- **Polling a log can miss events not in the log and lag.** `--once` is a
  batch read; continuous `--watch` is out of scope here (see ADR 036).
- **A rotated/truncated log at the same path keeps the same `instance_id`.**
  Replacing the file with shorter content after a watermark of `N` yields zero
  new events (lines `> N` do not exist); replacing it with longer content
  resumes at `N+1` even though the earlier lines changed. This is the path-hash
  trade-off: it survives legitimate appends but cannot detect a log rotation
  that rewrites history. The mitigation is the runner's
  `ObserverCheckpointInstanceMismatch` check against the path hash; if a user
  intentionally rotates a log in place, they delete
  `.agit/observers/jsonl.json` to reset.
- **Whole-file read, not streaming.** The 4 MiB cap bounds memory and matches
  the fixture source; long-tailing very large logs will need streaming reads
  before this leaves experimental.
- **Self-selected schema, not a real agent's.** This is a reusable JSONL shape,
  chosen to prove the framework without hard-coding one agent's quirks, as
  ADR 028 step 4 directs ("add one thin adapter at a time").

## Why this source first

A line-oriented JSONL shape is the de-facto requirement for a safe first real
source (binary or non-length-delimited formats are explicitly a STOP
condition in the plan). It is reusable across any agent that can emit one
JSON object per line, and it lets the framework prove checkpoint dedup over a
monotonic positional watermark before specializing to a specific agent's log.

## Consequences

- The observer registry now ships two sources: `fixture` (synthetic) and
  `jsonl` (experimental).
- `agit observe --once jsonl --input <log>` is usable today; `--once` only.
- The source is marked `experimental: true` per ADR 028 step 6. Promotion out
  of experimental requires documenting a real agent's log format and adding
  fixtures, per ADR 028's testing expectations.

## References

- ADR 028 — Observer-based integrations for agents without lifecycle hooks
- ADR 036 — Live-follow / `--watch` view (separate; continuous mode out of scope here)

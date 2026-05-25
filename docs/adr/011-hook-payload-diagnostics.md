# ADR 011: User-friendly hook payload diagnostics

**Status:** Accepted
**Date:** 2026-05-25

## Context

Hook commands read JSON from stdin and parse it with `std.json`:

- `src/cli/claude_hook.zig:41`
- `src/cli/codex_hook.zig:35`
- `src/cli/gemini_hook.zig:35`

When parsing fails, the call site bubbles a raw Zig error like
`error.UnexpectedToken` up to `src/hook.zig:reportFailure` (lines ~98–129).
`reportFailure` then *reparses* the payload to extract `session_id` and
`hook_event_name` for the log line. If the payload is malformed, this second
parse also fails or partially succeeds, and the resulting hook-error log
entry is some flavour of useless.

Three concrete weaknesses:

1. Users see `error.UnexpectedToken` in their agent's stderr. There is no
   indication of which field, which byte offset, or even which agent.
2. `reportFailure` allocates and reparses a potentially huge payload on the
   error path — exactly when we want to do *less* work.
3. The hook-error log line is structured around fields that might not exist
   when parsing failed, so we either drop the entry or write `null` for
   everything useful.

## Decision

1. Introduce a single `hook.readPayload` helper that:
   - Reads stdin into a bounded buffer (default 16 MiB, configurable via
     `AGIT_HOOK_MAX_BYTES`).
   - Parses incrementally and captures the first parse-error offset.
   - Returns either a typed `Payload` or a `PayloadParseError{path, offset,
     line, column, snippet, raw_size}`.
2. Pass *extracted metadata* (`session_id`, `agent`, `event`) through to
   `reportFailure` as already-resolved values. `reportFailure` never reparses.
3. The hook-error log line is structured JSON with fields: `ts`, `agent`,
   `event`, `session_id`, `error_kind`, `error_msg`, `payload_size`,
   `payload_snippet` (first 256 bytes, redacted of obvious secrets).
4. Hook stderr is human-readable and includes:
   - which agent sent the payload,
   - which field/byte offset is bad,
   - how to inspect the captured payload (`agit doctor --last-hook-error`).

## Plan

1. Add `src/hook.zig:readPayload` and `PayloadParseError`.
2. Refactor the three hook command files (Claude, Codex, Gemini) to use
   `readPayload` and to thread extracted metadata to `reportFailure`.
3. Change `reportFailure` to accept resolved metadata; remove the reparse.
4. Add a JSON-line log format for `.agit/log/hook-error.log` and a small
   reader at `agit doctor --last-hook-error`.
5. Add a secrets-redaction pass to the snippet (strip values for keys
   matching `/token|key|secret|password|authorization/i`).

## Testing

- Property test: random-fuzzed JSON payloads → `readPayload` either parses
  or returns `PayloadParseError` with a valid offset.
- Unit tests for redaction: keys that should be redacted are, keys that
  shouldn't aren't.
- Integration test: pipe a malformed payload to each hook command, assert
  stderr names the agent and offset, assert hook-error log line is a
  parseable JSON object, assert exit code stays 0 (per ADR 003 — hooks
  must not break the agent).
- Size cap test: payload > `AGIT_HOOK_MAX_BYTES` returns a typed error
  rather than OOMing.

## Risks and tradeoffs

- A 16 MiB cap will reject pathological payloads but no real Claude/Codex/
  Gemini payload we've seen comes close. Tunable via env var if needed.
- Secrets redaction is best-effort by regex; we will miss novel field
  names. Document this explicitly and keep the snippet small.
- Adding structured JSON to the hook log changes its on-disk format. We
  version-stamp the log header and ship a tiny migration in `doctor`.

## Consequences

- When something goes wrong with capture, the user gets an actionable
  message and a place to look. The "why is agit silent?" support load
  drops.
- The error path stops doing redundant work.
- Hook-error log entries become machine-readable, enabling future
  `agit log --errors` views and richer `doctor` output.

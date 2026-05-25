# ADR 026: Privacy and redaction controls for captured session data

**Status:** Proposed
**Date:** 2026-05-25

## Context

Snapshot filtering is intentionally conservative (ADR 004), and hook-error
snippets are planned to redact obvious secrets (ADR 011). That still leaves a
larger privacy surface:

- prompts may contain credentials or private customer data,
- tool arguments may include environment variables or file contents,
- tool results may contain command output with tokens,
- `agit cat`, `agit show`, `agit grep`, export, and remote sync can make
  sensitive local history easier to inspect or share.

The README correctly tells users to treat `.agit/` as private local history, but
future sharing features need stronger product rules than "be careful".

## Decision

Add a first-class privacy policy and redaction engine before building sharing
features on top of the store.

1. **Policy file:** use `.agit/config.json` (ADR 002) for repository-local
   capture policy. The initial shape includes:
   - enabled origins,
   - capture level for prompts, tool arguments, tool results, and snapshots,
   - custom redaction patterns,
   - export/remote safety defaults.
2. **Built-in redaction:** provide a shared redactor for obvious secret keys and
   values (`token`, `secret`, `password`, `authorization`, private-key blocks,
   and common cloud credential names). The rule set is documented as
   best-effort.
3. **Capture-time controls:** allow users to choose between full capture,
   redacted capture, metadata-only capture, or disabled capture per data class.
   The default remains full local capture for compatibility until a major
   release changes it deliberately.
4. **Share-time gates:** `agit export` and `agit push` must run a privacy scan
   unless the user passes an explicit override. Plaintext export/push requires
   either a clean scan or `--allow-sensitive`.
5. **Display-time controls:** user-facing commands that print captured content
   gain a `--redacted` mode and a config option to make redacted output the
   default.

## Plan

1. Add `src/privacy/redact.zig` with a small deterministic rule engine and
   tests.
2. Add `.agit/config.json` load/validate helpers under `src/store/config.zig`.
3. Thread capture policy into hook adapters and recorder writes.
4. Add `agit privacy scan` to walk reachable objects and report findings by
   severity without printing secret values.
5. Require privacy-scan integration from export/import (ADR 027) and remote
   sync (ADR 023) before those commands can upload or bundle data.

## Testing

- Unit tests for built-in redaction patterns and custom pattern matching.
- Golden tests proving redacted output does not include the sensitive values it
  detected.
- E2E test: set metadata-only tool-result capture, record a hook payload, and
  assert tool result content is absent from the step object.
- E2E test: `agit privacy scan` finds a synthetic token in a prompt and blocks
  export/push without an explicit override.

## Risks and tradeoffs

- Redaction cannot be perfect. The UI and docs must avoid implying that it is.
- Capture-time redaction is irreversible. Users who need complete forensic
  history must be able to opt into full local capture.
- Scanning the whole store may be slow; provide session/date filters and reuse
  reachability traversal from `fsck`.

## Consequences

- Sharing features have a clear safety gate instead of bolting warnings on at
  the end.
- Users can tune capture to match their repository's sensitivity.
- Local-first behavior remains intact, while export and remote sync become
  safer by default.

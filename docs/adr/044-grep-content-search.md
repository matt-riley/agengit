# ADR 044: Grep Content Search

Date: 2026-06-21
Status: accepted

## Context

`agit grep` searches agent activity (messages, tool calls, tool results) via the FTS5
index on step content. There is no way to search the captured workspace blobs that are
already stored content-addressed under `objects/`. Questions like "what file did the
agent change that contained X three sessions ago" are unanswerable even though every
needed byte exists in the store.

## Decision

Add a `--content` flag to `agit grep` that switches from FTS5 message/tool search to a
blob-body scan. The implementation:

1. **Enumerates reachable blobs** by walking the step → tree → blob chain from
   session HEAD refs (reusing the same dedup-by-hash pattern as `privacy scan`).

2. **Applies the same filters** as activity grep: `--origin`, `--session`,
   `--since`, `--until`, `--limit`.

3. **Performs case-insensitive substring matching** on blob content. This is a
   scan, not an index — the design accepts a linear cost for the MVP.

4. **Respects capture policy**: blobs from `.metadata_only` or `.disabled`
   snapshots are placeholder strings that start with `metadata_only_marker`.
   These are silently skipped so content search never leaks information the user
   chose not to record.

5. **Reuses the privacy redaction stack**: `redact_mod.redactAlloc` runs on
   snippet text before display, the same as activity grep, `--redacted` /
   `--full` controls apply.

6. **Uses a distinct `entry_kind`** (`"content"`) so JSON consumers can
   distinguish content matches from message/tool matches.

7. **Hard candidate cap**: a `max_candidates` ceiling (4096 by default) prevents
   unbounded scan time on stores with millions of blobs.

## Consequences

- `agit grep --content <query>` now answers captured-file-content questions.
- No new persistent index or storage; the scan is read-only on existing objects.
- Performance is O(captured blob count × query length) and acceptable for the
  typical store size. A future FTS index on blob content (or embedding-based
  search) can replace the scan path without changing the CLI contract.
- Privacy surface: the scan reads the same blob bodies already accessible via
  `agit cat` and the `privacy scan` command. No new data is exposed.
- The `content_search.zig` module is reusable by future commands (e.g., a
  structured "find content changes between sessions" command).
- `.disabled` snapshots have no tree entries and produce no content results.
  `.metadata_only` snapshots have tree entries but placeholder blob bodies —
  the `isSnapshotPlaceholder` guard skips them silently.

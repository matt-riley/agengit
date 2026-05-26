# ADR 022: Historical content search (agit grep)

**Status:** Implemented
**Date:** 2026-05-25

## Context

Users often need to find a specific past interaction with an agent:
"When did I ask about the authentication logic?"
"What was the output of that `bash` command I ran three days ago?"

Currently, finding this information requires manually scanning `agit sessions`
and `agit log`, which is tedious once the repository has dozens of recorded
sessions and hundreds of turns.

## Decision

Implement an `agit grep` command that provides full-text search across all
recorded sessions:

1. **SQLite FTS5 Integration:** Enable the FTS5 extension in the SQLite
   `index.db`. Add an FTS5 virtual table populated from `messages` and
   `tool_calls` content.
2. **Search Scope:** By default, search all messages and tool call arguments/results
   across all sessions in the current repository.
3. **Filtering:** Support filtering by agent origin (`--origin`), session ID
   (`--session`), and date range (`--since`, `--until`).
4. **Output Format:** Provide a "match-centric" output that shows the session ID,
   turn ID, and a snippet of the matching text.

## Plan

1. Update `src/store/index.zig` to create the FTS5 virtual table and keep it
   in sync from the index write paths and `agit reindex`.
2. Implement the `grep` command in `cli/grep.zig`.
3. Add support for "context" (showing lines before/after the match).
4. Update `agit reindex` to also rebuild the FTS5 index.

## Testing

- Integration test: record several turns with specific keywords, run
  `agit grep`, and assert that the correct steps are identified.
- Performance test: measure search latency on a database with 10k messages
  and 10k tool calls.
- UI test: ensure matches are highlighted in the terminal output.

## Risks and tradeoffs

- **Database Size:** The FTS5 index will increase the size of `index.db`.
  However, `index.db` is already rebuildable, and the textual content of
  messages/tool_calls is relatively small compared to workspace snapshots.
- **Search Complexity:** Complex regex support in FTS5 can be limited
  compared to specialized search engines, but it is sufficient for common
  CLI use cases.

## Consequences

- Discoverability of past agent knowledge is significantly improved.
- `agit` becomes a more powerful diagnostic and auditing tool.
- The `index.db` becomes a more central and valuable part of the system.

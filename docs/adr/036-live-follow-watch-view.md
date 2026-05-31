# ADR 036: Live follow and watch view

**Status:** Implemented
**Date:** 2026-05-31

## Context

Today's read commands are point-in-time: `agit status`, `agit timeline`, and
`agit sessions` each render a snapshot of the store and exit. To watch an agent
work, a user must re-run a command in a loop. There is no way to follow recorded
activity as it streams in.

Because hooks finalize steps continuously while an agent runs, a live "follow"
view is a natural fit: it would let a user observe prompts, tool calls, and file
changes in near real time — useful for long agent runs, debugging hook
delivery, and simply seeing what an agent is doing right now.

## Decision

Add `agit watch`, a live-follow view that streams newly finalized steps until
interrupted. The implemented scope is the canonical plain streaming mode; the
optional interactive TUI is deferred to future work.

1. **Streaming default:** `agit watch` tails newly committed steps and prints
   one compact line per step (timestamp, origin, session, turn, tool/preview)
   as they appear, similar to `tail -f`. This mode requires no TTY and works in
   pipes and CI logs.
2. **Change detection:** watch polls the index for new committed steps on a short
   interval, rather than depending on filesystem notification APIs, to stay
   portable and fail-open. It uses SQLite insertion order as its internal cursor
   so late-finalized steps with older display timestamps are not skipped. The
   interval is configurable via `--interval`.
3. **Filters:** support `--origin`, `--session`, and `--since` to scope the
   stream, reusing the same filters as `agit timeline`.
4. **Optional TUI deferred:** a future follow-up may add an explicit `--tui`
   dashboard for active sessions, latest step per session, and recent tool
   calls. It is not part of this implementation; streaming text mode remains
   canonical.
5. **Read-only and bounded:** watch never writes to the store, holds no locks
   beyond normal index reads, and exits cleanly on SIGINT, printing a final
   summary count.

## Plan

1. Add an index query that returns committed steps newer than a given SQLite
   row cursor, ordered ascending.
2. Implement `cli/watch.zig` streaming mode, polling the cursor query on
   `--interval` and printing timeline-style lines or `cli-json-v1` JSON lines.
3. Add `--origin`/`--session`/`--since` filters using timeline-equivalent
   semantics.
4. Ensure clean SIGINT/SIGTERM handling and a final summary line.
5. Add README examples after implementation; document that watch is polling and
   near-real-time, not event-driven.

## Testing

- E2E test: start `agit watch` in streaming mode, record steps from a hook, and
  assert the new steps appear on the stream within a bounded interval.
- E2E test: `--session` filter only streams steps for the selected session.
- E2E test: watch exits 0 on interrupt and prints a final count.
- E2E test: watch on an empty store prints nothing and exits cleanly on
  interrupt without busy-looping.
- JSON-line test: `--json --since` streams existing matching steps once and
  emits a final summary event.

## Risks and tradeoffs

- Polling adds latency and wakeups. A sensible default interval and a cursor
  query keep it cheap; this is explicitly "near real time," not event-driven.
- A TUI adds surface area and test complexity. Keeping streaming mode canonical
  means the TUI can never become a correctness dependency.
- Long-running watch in CI could hang jobs. Document that watch is interactive
  and provide `--once`-style scoping via existing timeline commands instead.

## Consequences

- Users can observe agent activity live instead of re-running snapshots.
- The streaming mode doubles as a debugging tool for hook delivery.
- The shared cursor query and render layer give future editor/IDE integrations
  a live data source.

# AgenGit research notes

These notes explain the thinking behind `agit` without pretending the whiteboard is still the product.

The original research compared `agit` with [`regent-vcs/re_gent`](https://github.com/regent-vcs/re_gent), checked the Zig 0.16 ecosystem, and explored possible agent integration paths. The implementation has since made several decisions of its own; this file now records the durable bits that still help readers understand the app.

## Core idea

AI agents make changes in little bursts: a prompt, a few tools, a response, another tool, a final answer. Git sees the final files after humans commit. `agit` records the trail of breadcrumbs that led there.

The useful model is:

1. A supported agent emits a hook event.
2. `agit` normalizes the event into a shared recorder shape.
3. The recorder snapshots the workspace and writes immutable objects.
4. A per-session ref points at the latest step.
5. A SQLite index makes the store pleasant to query.

## Borrowed inspiration

`re_gent` is the main reference point:

- content-addressed objects;
- per-session DAG-style history;
- BLAKE3 hashes;
- SQLite as a rebuildable index;
- hook commands that must not break the agent;
- future-facing concepts like line blame, rewind, forks, and sync.

`agit` intentionally does not claim byte compatibility with `re_gent`. It uses `.agit/` instead of `.regent/`, JSON config instead of TOML, and a Zig implementation tuned around the current app's needs.

## Why Zig

Zig is a good fit for this kind of tool because it can produce small cross-platform binaries, includes BLAKE3 in the standard library, has direct filesystem/process primitives, and works well for "ship one CLI and let hooks call it" workflows.

The trade-off is that Zig is still pre-1.0. `agit` pins Zig `0.16.0` so contributors and CI are using the same toolbox instead of three different magic wands.

Current dependencies are intentionally small:

| Need | Choice |
|---|---|
| CLI parsing | `zig-clap` |
| SQLite | `zqlite` |
| Hashing | `std.crypto.hash.Blake3` |
| JSON | `std.json` |
| Build/release | Zig build system and GitHub Actions |

## Agent integration findings

The current implementation supports hook-based capture for agents that expose useful lifecycle events:

| Agent | Current `agit` path |
|---|---|
| Claude Code | User prompt, post-tool-batch, and stop hooks |
| OpenAI Codex CLI | User prompt, post-tool-use, and stop hooks |
| Google Gemini CLI | After-tool and after-agent hooks |

Two agents remain interesting but unsolved in this repo:

| Agent | Why it needs more design |
|---|---|
| Pi (`pi.dev` coding agent) | Likely best served by filesystem observation first, then deeper RPC if needed. |
| GitHub Copilot CLI | No public lifecycle hooks; likely needs session-state/session-store observation or an MCP-based callout. |

## Store model

The `.agit/` directory is local and intentionally separate from `.git/`.

```text
.agit/
|-- objects/          # content-addressed canonical data
|-- refs/sessions/    # mutable session heads
|-- log/              # hook errors
|-- tmp/              # staging/atomic-write workspace
`-- index.db          # rebuildable query layer
```

The canonical rule is simple: objects first, index second. If the index goes sideways, `agit reindex` can rebuild it from objects.

## Snapshot policy

The original research treated snapshot safety as a first-class problem, and that remains true. The implementation skips common generated directories, `.git/`, `.agit/`, secret-looking filenames, symlinks, binary files, and files larger than 10 MiB.

That is a practical guardrail, not a guarantee that every secret in the universe has been detected. Users should treat `.agit/` as private local history.

## Decisions captured elsewhere

The durable architecture decisions live in ADRs:

- [ADR 001: Store directory](docs/adr/001-store-directory.md)
- [ADR 002: JSON configuration](docs/adr/002-config-format.md)
- [ADR 003: Hook process model](docs/adr/003-hook-process-model.md)
- [ADR 004: Snapshot policy](docs/adr/004-snapshot-policy.md)
- [ADR 005: Hook installation contract](docs/adr/005-hook-install-contract.md)

## Open research questions

- What is the least surprising way to capture Copilot CLI sessions without official hooks?
- Should Pi support begin as a filesystem observer, or is RPC useful enough to justify a larger first pass?
- What should a safe export format look like when session history may contain prompts, tool outputs, and file content?
- How much `re_gent` compatibility is worth carrying, and where would it create confusing promises?

If a future doc claims one of these is solved, the code should be able to prove it.

# AgenGit roadmap

This is the living map for `agit`: where the little session goblin already works, where it still needs boots, and which caves are deliberately left unexplored for now.

For user-facing setup and commands, start with [README.md](README.md). For decision history, follow the ADR trail in [`docs/adr/`](docs/adr/).

## Product shape

`agit` is a local AI-agent session recorder. It captures agent activity into a content-addressed `.agit/` store:

- immutable objects for blobs, trees, steps, and future blame data;
- per-session refs under `.agit/refs/sessions/`;
- a rebuildable SQLite index at `.agit/index.db`;
- hook-safe error logs under `.agit/log/`;
- a CLI for setup, inspection, reindexing, completions, and cleanup.

The goal is not to replace git. Git remains the source-control castle; `agit` is the map of the agent footprints around it.

## Current implementation

| Area | Status | Notes |
|---|---|---|
| Zig CLI scaffold | Done | Binary name is `agit`; Zig target is `0.16.0`. |
| Content-addressed store | Done | BLAKE3 objects under `.agit/objects/<prefix>/<hash>`. |
| SQLite index | Done | Sessions, steps, messages, and tool calls are queryable and rebuildable. |
| Workspace snapshots | Done | Skips ignored paths, symlinks, binary files, and files over 10 MiB. |
| Recorder engine | Done | Normalizes prompt/tool/assistant events into step objects. |
| Claude Code hooks | Done | Captures user prompts, tool batches, and assistant stop events. |
| Codex CLI hooks | Done | Captures prompt, tool-use, and stop events. |
| Gemini CLI hooks | Done | Captures after-tool and after-agent events. |
| User CLI | Mostly done | `status`, `sessions`, `log`, `show`, `cat`, `reindex`, `completion`, `doctor`, `init`, and `uninstall` exist. |
| Line blame | Done | `agit blame <file>` renders per-line step attribution, recorded at finalize and rebuildable via `agit reindex`. |
| Pi support | Not started | Planned filesystem-observer path for the `pi.dev` coding agent. |
| GitHub Copilot CLI support | Not started | Needs observer/MCP design because Copilot has no public lifecycle hooks. |
| Release automation | Done | CI builds release archives, checksums, Release Please releases, and optional Homebrew formula updates. |

## User-facing command goals

| Command | Purpose | Status |
|---|---|---|
| `agit init` | Detect supported agents and install hooks with backups. | Done |
| `agit uninstall` | Remove only `agit`-managed hooks. | Done |
| `agit doctor` | Check `.agit/` health and hook binary paths. | Done |
| `agit status` | Show recorded session and step counts. | Done |
| `agit sessions` | List recorded sessions. | Done |
| `agit log [session]` | Show step history for a session. | Done |
| `agit show <hash>` | Inspect a step object. | Done |
| `agit cat <hash>` | Print a raw object. | Done |
| `agit reindex` | Rebuild SQLite rows from object data. | Done |
| `agit completion <shell>` | Generate bash, zsh, fish, or Nushell completions. | Done |
| `agit blame <path>` | Show per-line agent-step attribution. | Planned |

## Near-term work

1. Make `agit blame` real by wiring blame-map writes into finalized steps and teaching the CLI to resolve line attribution.
2. Tighten hook event fidelity, especially turn ids and richer assistant/tool metadata where agents provide it.
3. Improve `doctor` so it can explain common misconfigurations with "fix this next" guidance instead of only status lines.
4. Add more golden-output tests for the human-facing CLI.
5. Document and test `.agitignore` behavior with practical examples.

## Later work

| Idea | Why it matters | Notes |
|---|---|---|
| Pi observer | Captures another active coding-agent workflow. | Likely filesystem-first for the `pi.dev` coding agent. |
| Copilot observer | Makes `agit` useful for Copilot CLI sessions. | Needs session-state/session-store research and probably an MCP option. |
| `fsck` | Lets users verify store integrity. | Should check object hashes, refs, and index consistency. |
| Garbage collection | Keeps long-running stores tidy. | Needs a safe grace period and clear docs. |
| Import/export | Gives users portable session bundles. | Must avoid leaking secrets. |
| `.regent/` migration | Helps users coming from `re_gent`. | Only after format compatibility is deliberately designed. |

## Non-goals for now

- No byte-compatible `.regent/` store promises.
- No remote sync, push/pull, or hosted service.
- No hidden network calls.
- No claim that `.agit/` is safe to publish.
- No requirement that hooks block or control the agent. Capture should be helpful, not bossy.

## Validation checklist

Use these before a release:

```sh
zig build test
zig build check-fmt
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseSafe
```

The docs should stay honest: if the binary cannot do it today, call it planned.

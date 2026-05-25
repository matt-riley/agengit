# AgenGit

`agit` is a CLI that records AI-agent coding activity into a local `.agit/`
store so you can inspect what happened between commits.

## Status

Current CLI version: `1.11.1`. <!-- x-release-please-version -->

The project is usable but still evolving. Command output and on-disk details may
change before a long-term stable format is declared.

Supported hook integrations today:

| Agent | Installed hooks |
|---|---|
| Claude Code | `UserPromptSubmit`, `PostToolBatch`, `Stop` in `~/.claude/settings.json` |
| OpenAI Codex CLI | `UserPromptSubmit`, `PostToolUse`, `Stop` in `~/.codex/hooks.json` |
| Google Gemini CLI | `AfterTool`, `AfterAgent` in `~/.gemini/settings.json` |

## What gets recorded

Each captured step includes agent origin, session identifiers, messages, tool
calls, a workspace snapshot, and a content-addressed object hash.

In practice: Git tracks commit history, while `agit` tracks agent execution
history.

## Install

### From release archives

Download from <https://github.com/matt-riley/agengit/releases>.

| Platform | Archive |
|---|---|
| Linux x86_64 | `agit-x86_64-linux.tar.gz` |
| Linux aarch64 | `agit-aarch64-linux.tar.gz` |
| macOS arm64 | `agit-aarch64-macos.tar.gz` |
| macOS x86_64 | `agit-x86_64-macos.tar.gz` |

```sh
tar -xzf agit-x86_64-linux.tar.gz
sudo mv agit /usr/local/bin/
agit version
```

### Build from source

Requires Zig `0.16.0`.

```sh
git clone https://github.com/matt-riley/agengit
cd agengit
zig build -Doptimize=ReleaseSafe
./zig-out/bin/agit version
```

## Quick start

From the repository you want to observe:

```sh
agit init
```

`agit init` discovers supported agent CLIs on `PATH` and installs hook commands
into their user config files, creating `*.agit.bak` backups first.

If a target config file exists but is malformed JSON, `agit init` will not
overwrite it unless you run `agit init --force`.

## Core commands

```sh
agit doctor                 # store + hook health checks
agit doctor --locks         # include lock-file details
agit doctor --stats         # print finalize/object-write counters
agit status                 # summarize captured state
agit sessions               # list sessions
agit log                    # latest session timeline
agit log <session-id>       # specific session timeline
agit log claude/<session-id>
agit show <step-hash>       # detailed step view
agit cat <hash>             # raw object payload
agit reindex                # rebuild index from object store
agit reindex --from <hash>  # incremental replay
agit completion zsh         # shell completions (bash/zsh/fish/nushell)
agit uninstall              # remove agit-managed hooks
```

`agit blame` is present but currently reports that blame recording is not yet
available.

## Store layout

`agit` stores data in `.agit/` at repository root:

```text
.agit/
|-- objects/          # BLAKE3-addressed blobs, trees, steps
|-- refs/
|   `-- sessions/     # latest step pointer per session
|-- log/
|   `-- hook-error.log
|-- tmp/              # staging + temporary writes
`-- index.db          # rebuildable SQLite index
```

Do not commit `.agit/`. Canonical history is in `objects/`; `index.db` is a
query accelerator and can be rebuilt with `agit reindex`.

## Snapshot and privacy notes

By default, snapshots skip `.git/`, `.agit/`, common dependency/build/cache
directories, symlinks, binary files, files larger than 10 MiB, and common
secret-like file patterns.

Project-specific exclusions can be added via `.agitignore` using exact paths,
directory-prefix rules (trailing slash), and single `*` glob patterns.

Secret filtering helps reduce risk but is not a hard guarantee. Treat `.agit/`
as private data unless reviewed.

## Failure behavior

Hooks are fail-open: if capture fails, the hook logs the error and exits
successfully so the coding agent can continue.

For capture issues:

```sh
agit doctor
cat .agit/log/hook-error.log
```

## Development

```sh
zig build
zig build run -- version
zig build test
zig build test-e2e
zig build bench-durable
zig build fmt
zig build check-fmt
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
```

Durability fsync is enabled by default. Use `AGIT_FSYNC=0` only in tests or
microbenchmarks where you intentionally skip directory fsync.

Lock acquisition timeout defaults to 10 seconds. Override with
`AGIT_LOCK_TIMEOUT_MS=<milliseconds>` for contention diagnostics.

Regenerate e2e golden files intentionally:

```sh
AGIT_UPDATE_GOLDEN=1 zig build test-e2e
```

## Architecture decisions

Key design rationale is documented under [`docs/adr/`](docs/adr/), including:

- [ADR 001: Store directory](docs/adr/001-store-directory.md)
- [ADR 002: JSON configuration](docs/adr/002-config-format.md)
- [ADR 003: Hook process model](docs/adr/003-hook-process-model.md)
- [ADR 004: Snapshot policy](docs/adr/004-snapshot-policy.md)
- [ADR 005: Hook installation contract](docs/adr/005-hook-install-contract.md)

## License

GNU General Public License v3.0. See [LICENSE](./LICENSE).

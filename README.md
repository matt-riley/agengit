# AgenGit

`agit` is a little black box for AI coding sessions.

It watches supported coding agents, records the prompts/tools/responses that shaped a workspace, and tucks everything into a local `.agit/` store so you can ask, "What happened here?" without rummaging through terminal scrollback like a raccoon in a filing cabinet.

## Status

`agit` is early, sharp-edged, and useful-in-progress. The CLI is currently `1.6.0`, and both the command output and on-disk format may change before a stable release. <!-- x-release-please-version -->

Today it focuses on local capture for:

| Agent | What `agit` installs today |
|---|---|
| Claude Code | `UserPromptSubmit`, `PostToolBatch`, and `Stop` hooks in `~/.claude/settings.json` |
| OpenAI Codex CLI | `UserPromptSubmit`, `PostToolUse`, and `Stop` hooks in `~/.codex/hooks.json` |
| Google Gemini CLI | `AfterTool` and `AfterAgent` hooks in `~/.gemini/settings.json` |

Pi (the `pi.dev` coding agent) and GitHub Copilot CLI support are roadmap items, not current user-facing commands.

## What it records

When an installed hook fires, `agit` records a session step containing the agent origin, session id, turn id, messages, tool calls, a workspace snapshot, and a content-addressed object hash.

The short version: git remembers what humans commit; `agit` remembers what the agent did between commits.

## Install

### From a release archive

Download a release from <https://github.com/matt-riley/agengit/releases>, then unpack the archive for your platform:

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

You need Zig `0.16.0`.

```sh
git clone https://github.com/matt-riley/agengit
cd agengit
zig build -Doptimize=ReleaseSafe
./zig-out/bin/agit version
```

## First run

From the repository you want to observe:

```sh
agit init
```

`agit init` looks for `claude`, `codex`, and `gemini` on your `PATH`. For each one it finds, it writes hook configuration into that agent's user config and saves a `*.agit.bak` backup first.

Existing config files must be valid JSON objects. If a config file is malformed, `agit init` refuses to overwrite it; fix the JSON or rerun `agit init --force` to back up and replace that config deliberately.

If none of those agents are installed, `agit init` politely shrugs and does nothing.

## Everyday commands

```sh
# Check that the store and agent hook config look healthy.
agit doctor

# See how many sessions and steps have been recorded.
agit status

# List captured agent sessions.
agit sessions

# Show the step history for the most recent session.
agit log

# Or show a specific session by id, or by origin/session-id.
agit log <session-id>
agit log claude/<session-id>

# Inspect one recorded step.
agit show <step-hash>

# Print a raw object from the local object store.
agit cat <hash>

# Rebuild the SQLite index from objects if it gets out of step.
agit reindex

# Generate shell completions.
agit completion bash
agit completion zsh
agit completion fish
agit completion nushell

# Remove agit-managed hooks while keeping the recorded store.
agit uninstall
```

`agit blame` exists in the command list, but line-level blame recording is not available yet. Consider it a signpost with a tiny hard hat.

## Store layout

`agit` stores data in `.agit/` at the root of the repository being observed:

```text
.agit/
|-- objects/          # BLAKE3-addressed blobs, trees, and steps
|-- refs/
|   `-- sessions/     # Mutable pointers to each session's latest step
|-- log/
|   `-- hook-error.log
|-- tmp/              # Hook staging files and temporary writes
`-- index.db          # Rebuildable SQLite query index
```

Do not commit `.agit/`. It is local session history, not source code.

The canonical data lives in the object store; `index.db` is a query helper that can be rebuilt with `agit reindex`.

## Snapshot safety

Snapshots are intentionally conservative. By default `agit` skips `.git/`, `.agit/`, common dependency/build/cache directories, common secret-looking files, symlinks, binary files, and files larger than 10 MiB.

You can add project-specific ignore rules in `.agitignore` at the repository root. The matcher is intentionally simple today: exact paths, trailing-slash directory prefixes, and single-`*` glob patterns.

Skipped files are not written into the captured tree. Use `agit show <step-hash>` to inspect what a step did capture, and use `agit doctor` plus `.agit/log/hook-error.log` when capture state looks corrupt or incomplete.

Secret filtering is a safety net, not a force field. Keep `.agit/` private unless you have reviewed what it contains.

## How hooks behave

Hook commands are designed to stay out of the agent's way. If capture fails, the hook logs an error and exits successfully so Claude, Codex, or Gemini can keep working.

That means missed captures should be debugged with:

```sh
agit doctor
cat .agit/log/hook-error.log
```

## Development

```sh
zig build test
zig build test-e2e
zig build check-fmt
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
```

E2E golden files live under `tests/golden/`. Regenerate them intentionally with:

```sh
AGIT_UPDATE_GOLDEN=1 zig build test-e2e
```

The repository also has GitHub Actions for Linux/macOS tests, release archive builds, checksums, Release Please, and an optional Homebrew tap update.

## Design notes

The short version lives here; the "why did we choose that?" trail lives in the ADRs:

- [ADR 001: Store directory](docs/adr/001-store-directory.md)
- [ADR 002: JSON configuration](docs/adr/002-config-format.md)
- [ADR 003: Hook process model](docs/adr/003-hook-process-model.md)
- [ADR 004: Snapshot policy](docs/adr/004-snapshot-policy.md)
- [ADR 005: Hook installation contract](docs/adr/005-hook-install-contract.md)

## License

GNU General Public License v3.0. See [LICENSE](./LICENSE).

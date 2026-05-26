# AgenGit

`agit` is a CLI that records AI-agent coding activity into a local `.agit/`
store so you can inspect what happened between commits.

## Status

Current CLI version: `1.13.0`. <!-- x-release-please-version -->

The project is usable but still evolving. Command output and on-disk details may
change before a long-term stable format is declared.

## Today

Shipping today: local `.agit/` capture stores, hook installation for Claude
Code/OpenAI Codex CLI/Google Gemini CLI, health/recovery tooling including
read-only `agit fsck`, generated shell completions, and structured JSON for
the commands that advertise it.

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

If a target config file exists but contains malformed or non-object JSON,
`agit init` refuses to overwrite it unless you rerun with `agit init --force`.

## Commands

<!-- BEGIN COMMANDS -->
### `agit init`
Set up agit hooks for installed agent CLIs.

**Synopsis:** `agit init [OPTIONS]`

```sh
# install hooks for available agents
agit init
```

### `agit uninstall`
Remove agit hooks from agent configurations.

**Synopsis:** `agit uninstall [OPTIONS]`

```sh
# remove all hooks
agit uninstall
```

### `agit doctor`
Check store health and agent hook configuration.

**Synopsis:** `agit doctor [OPTIONS]`

```sh
# check store and agent health
agit doctor
```

### `agit fsck`
Verify object, ref, index, and mutable-area integrity.

**Synopsis:** `agit fsck [OPTIONS]`

```sh
# run a read-only integrity scan
agit fsck
```

### `agit status`
Show current repository state and agit store statistics.

**Synopsis:** `agit status [OPTIONS]`

```sh
# show repository status
agit status
```

### `agit sessions`
List recorded agent sessions from the index.

**Synopsis:** `agit sessions [OPTIONS]`

```sh
# list all sessions
agit sessions
```

### `agit log`
Show step history for a session.

**Synopsis:** `agit log [OPTIONS] [SESSION_ID]`

```sh
# show most recent session steps
agit log
```

### `agit show`
Show details of a recorded step object by its BLAKE3 hash.

**Synopsis:** `agit show [OPTIONS] <HASH>`

```sh
# show details of a step
agit show abc123def
```

### `agit blame`
Show per-line step attribution for a file path.

**Synopsis:** `agit blame [OPTIONS] <FILE>`

```sh
# show blame for a file
agit blame src/main.zig
```

**Notes:** Blame recording is not yet available. When blame rendering lands, AGIT_MAX_FILE_BYTES will set the default large-file cap and --no-limits will disable it for one run.

### `agit cat`
Print a raw object by its BLAKE3 hash.

**Synopsis:** `agit cat [OPTIONS] <HASH>`

```sh
# print object content
agit cat abc123def
```

### `agit reindex`
Rebuild the SQLite index from object/ref truth.

**Synopsis:** `agit reindex [OPTIONS]`

```sh
# rebuild entire index
agit reindex
```

### `agit version`
Print agit version information.

**Synopsis:** `agit version [OPTIONS]`

```sh
# print the current version
agit version
```

### `agit completion`
Generate shell completion scripts for bash, zsh, fish, or nushell.

**Synopsis:** `agit completion [OPTIONS] <SHELL>`

```sh
# bash completion script
agit completion bash
```
<!-- END COMMANDS -->

## Roadmap

Planned but not shipped today:

- privacy/redaction controls before broader export/search features
- garbage collection and packfiles for long-lived stores
- historical content search and investigation-focused views
- remote sync plus portable export/import bundles
- observer-based integrations and additional agent targets such as Pi and
  GitHub Copilot CLI

Structured CLI output uses the `cli-json-v1` envelope documented in
[`docs/format/cli-json-v1.md`](docs/format/cli-json-v1.md).

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

If `agit doctor` reports that the object index cache is not backfilled after an
upgrade, run `agit reindex` once to repopulate it from `.agit/objects/`.

## Snapshot and privacy notes

By default, snapshots skip `.git/`, `.agit/`, common dependency/build/cache
directories, symlinks, binary files, files larger than 16 MiB, and common
secret-like file patterns. Override the cap with `AGIT_MAX_FILE_BYTES=<bytes>`
when you need to inspect unusually large text files.

Project-specific exclusions can be added via `.agitignore` using exact paths,
directory-prefix rules (trailing slash), and single `*` glob patterns.

Secret filtering helps reduce risk but is not a hard guarantee. Treat `.agit/`
as private data unless reviewed.

## Failure behavior

Hooks are fail-open: if capture fails, the hook logs the error and exits
successfully so the coding agent can continue.

For capture issues:

```sh
agit doctor --last-hook-error
cat .agit/log/hook-error.log | jq
```

Hook payload reads are capped at 16 MiB by default. Override with
`AGIT_HOOK_MAX_BYTES=<bytes>` for unusually large payloads.

## Development

```sh
zig build
zig build run -- version
zig build docgen
zig build check
zig build check-docgen
zig build test
zig build test-e2e
zig build test-property
zig build fuzz-hooks -- --time=60s
zig build bench-durable
zig build bench-store
zig build bench-resolve-prefix
./scripts/smoke-doctor.sh
zig build fmt
zig build check-fmt
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
```

Run `zig build check` before pushing. It covers formatting, markdown link
validation, release metadata validation, and unit tests. Keep
`zig build test-e2e` as the follow-up command when you touch behavior that needs
end-to-end coverage.

If you change command help, examples, or public usage specs, run
`zig build docgen` before pushing so the generated README command section stays
in sync.

Durability fsync is enabled by default. Use `AGIT_FSYNC=0` only in tests or
microbenchmarks where you intentionally skip directory fsync.

Lock acquisition timeout defaults to 10 seconds. Override with
`AGIT_LOCK_TIMEOUT_MS=<milliseconds>` for contention diagnostics.

Large-file snapshot limits default to 16 MiB per file. Override with
`AGIT_MAX_FILE_BYTES=<bytes>` when benchmarking or capturing larger text files.

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

# AgenGit

`agit` is a CLI that records AI-agent coding activity into a local `.agit/`
store so you can inspect what happened between commits.

## Status

Current CLI version: `1.22.3`. <!-- x-release-please-version -->

The project is usable but still evolving. Command output and on-disk details may
change before a long-term stable format is declared.

## Today

Shipping today: local `.agit/` capture stores, hook installation for Claude
Code/OpenAI Codex CLI/Google Gemini CLI/GitHub Copilot CLI/Pi, investigation
views including `agit timeline`, `agit show --files/--stat`, `agit diff`, and
`agit recall`, health/recovery tooling including read-only `agit fsck`,
S3-compatible remote `agit push` / `agit pull`, generated shell completions,
and structured JSON for the commands that advertise it.

Supported hook integrations today:

| Agent | Installed hooks |
|---|---|
| Claude Code | `UserPromptSubmit`, `PostToolBatch`, `Stop` in `~/.claude/settings.json` |
| OpenAI Codex CLI | `UserPromptSubmit`, `PostToolUse`, `Stop` in `~/.codex/hooks.json` |
| Google Gemini CLI | `AfterTool`, `AfterAgent` in `~/.gemini/settings.json` |
| GitHub Copilot CLI | generated extension `~/.copilot/extensions/agit-recorder/extension.mjs` (subscribes to `onUserPromptSubmitted`, `onPostToolUse`, `onAgentStop`) |
| Pi | generated extension `~/.pi/agent/extensions/agit-recorder.js` (auto-discovered) |

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
into their user config files or writes generated recorder extensions for agents
that expose public extension hooks. JSON config installs create `*.agit.bak`
backups first.

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

### `agit observe`
Run an experimental observer source and record newly seen events.

**Synopsis:** `agit observe [OPTIONS] <SOURCE>`

```sh
# process a fixture-backed observer file once
agit observe --once fixture --input observer.json
```

**Notes:** Observer sources are explicit and experimental. Current sources run one pass and persist watermarks under .agit/observers/ for duplicate suppression on rerun.

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

### `agit gc`
Prune unreachable store data and stale temporary files.

**Synopsis:** `agit gc [OPTIONS]`

```sh
# prune unreachable store data with the default grace period
agit gc
```

### `agit push`
Upload reachable objects and session refs to a configured remote.

**Synopsis:** `agit push [OPTIONS]`

```sh
# push to the only configured remote
agit push
```

### `agit pull`
Download missing objects and refs from a configured remote.

**Synopsis:** `agit pull [OPTIONS]`

```sh
# pull from the only configured remote
agit pull
```

### `agit export`
Write a portable bundle containing selected session refs and reachable objects.

**Synopsis:** `agit export [OPTIONS] <PATH>`

```sh
# export all recorded sessions into a bundle directory
agit export dist/bundle
```

### `agit import`
Import a portable bundle after validating hashes and ref conflicts.

**Synopsis:** `agit import [OPTIONS] <PATH>`

```sh
# import a bundle directory
agit import dist/bundle
```

### `agit status`
Show the current investigation dashboard for this repository.

**Synopsis:** `agit status [OPTIONS]`

```sh
# show repository status
agit status
```

### `agit timeline`
Show recent recorded steps across sessions in reverse chronological order.

**Synopsis:** `agit timeline [OPTIONS]`

```sh
# show the most recent recorded steps
agit timeline
```

### `agit eval`
Evaluate captured agent sessions using evidence-based quality signals.

**Synopsis:** `agit eval [OPTIONS]`

```sh
# evaluate the most recent recorded session
agit eval
```

**Notes:** Eval classifications are evidence-based signals from captured history, not proof of code correctness or production success.

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

### `agit restore`
Restore captured files from a step snapshot into the working tree. Whole-tree restores require --all; existing files are skipped unless --force is set.

**Synopsis:** `agit restore [OPTIONS] <HASH> [-- <PATH>...]`

```sh
# restore one captured file
agit restore abc123def -- src/main.zig
```

### `agit show`
Show details of a recorded step object by its BLAKE3 hash.

**Synopsis:** `agit show [OPTIONS] <HASH>`

```sh
# show details of a step
agit show abc123def
```

### `agit diff`
Render a diff for one step, between two steps, or across a session.

**Synopsis:** `agit diff [OPTIONS] (<HASH> [<HASH>] | --session <ID>) [-- <PATH>]`

```sh
# diff a recorded step against its parent
agit diff abc123def
```

### `agit between`
Show recorded steps whose captured Git commit falls between two revisions.

**Synopsis:** `agit between [OPTIONS] <FROM> [TO]`

```sh
# show steps recorded after one commit through HEAD
agit between abc123def
```

### `agit recall`
Retrieve prior recorded steps to inform the current task.

**Synopsis:** `agit recall [OPTIONS] [QUERY]`

```sh
# show recent prior work on one file
agit recall --path src/main.zig
```

**Notes:** Recall is agent-initiated pull memory. Pass a query, a --path filter, or both.

### `agit grep`
Search recorded messages and tool activity across all sessions.

**Synopsis:** `agit grep [OPTIONS] <QUERY>`

```sh
# search all recorded sessions for a term
agit grep factorial
```

### `agit blame`
Show per-line step attribution for a file path.

**Synopsis:** `agit blame [OPTIONS] <FILE>`

```sh
# show blame for a file
agit blame src/main.zig
```

**Notes:** AGIT_MAX_FILE_BYTES sets the default large-file cap and --no-limits disables it for one run.

### `agit watch`
Follow newly recorded steps as they are finalized.

**Synopsis:** `agit watch [OPTIONS]`

```sh
# follow newly recorded steps
agit watch
```

**Notes:** Watch polls the local SQLite index for committed steps and is near-real-time, not event-driven. Use `agit timeline` for one-shot CI output.

### `agit stats`
Summarize recorded session, step, tool, and file-change activity.

**Synopsis:** `agit stats [OPTIONS]`

```sh
# show repository-wide analytics
agit stats
```

**Notes:** Stats read the SQLite index; run `agit reindex` if the index has drifted. Most-changed paths are computed from at most 500 steps by default.

### `agit cat`
Print a raw object by its BLAKE3 hash.

**Synopsis:** `agit cat [OPTIONS] <HASH>`

```sh
# print object content
agit cat abc123def
```

### `agit privacy`
Scan reachable captured content for sensitive data without printing secret values.

**Synopsis:** `agit privacy scan [OPTIONS]`

```sh
# scan captured content for sensitive data
agit privacy scan
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

- historical content search
- portable export/import bundles

Experimental today: `agit observe --once fixture --input observer.json` exercises
the observer framework and persists replay checkpoints under
`.agit/observers/`.

Structured CLI output uses the `cli-json-v1` envelope documented in
[`docs/format/cli-json-v1.md`](docs/format/cli-json-v1.md).

## Store layout

`agit` stores data in `.agit/` at repository root:

```text
.agit/
|-- config.json        # repository-local privacy/capture policy
|-- objects/          # loose BLAKE3-addressed blobs, trees, steps, and pack/
|-- refs/
|   `-- sessions/     # latest step pointer per session
|-- log/
|   `-- hook-error.log
|-- tmp/              # staging + temporary writes
`-- index.db          # rebuildable SQLite index
```

Do not commit `.agit/`. Canonical history is in `objects/`; `index.db` is a
query accelerator and can be rebuilt with `agit reindex`. `agit gc` may repack
reachable loose objects into `.agit/objects/pack/` to reduce storage for
long-running repositories.

If `agit doctor` reports that the object index cache is not backfilled after an
upgrade, run `agit reindex` once to repopulate it from `.agit/objects/`.
If `doctor` reports pending capture files under `.agit/tmp`, those are
top-level staging files from turns that have not finalized yet. Fresh files are
usually an active turn; abandoned files older than the grace period are pruned
by `agit gc`. Internal turn-state files under `.agit/tmp/turns/` are not counted
as pending captures.

## Snapshot and privacy notes

By default, snapshots skip `.git/`, `.agit/`, common dependency/build/cache
directories, symlinks, binary files, files larger than 16 MiB, and common
secret-like file patterns. Override the cap with `AGIT_MAX_FILE_BYTES=<bytes>`
when you need to inspect unusually large text files.

Project-specific exclusions can be added via `.agitignore` using exact paths,
directory-prefix rules (trailing slash), and single `*` glob patterns.

Use `.agit/config.json` to tune capture levels for prompts, assistant messages,
tool arguments/results, and snapshots; disable origins; add custom literal
redactions; and make `show`/`cat` default to redacted output.

`.redacted` snapshot capture is best-effort, not a guarantee. For highly
sensitive repositories, prefer `.metadata_only` or `.disabled` snapshot capture.
Current detector coverage includes: bearer tokens, GitHub tokens, AWS access-key
IDs, AWS secret-access-key values near access-key IDs, private-key blocks,
Slack/Google/Stripe/OpenAI/npm token formats, JWTs, sensitive-key assignments,
and custom literals.

Run `agit privacy scan` before sharing store content. It reports sensitive-data
findings without printing the matched secret values and exits non-zero when
findings are present.

## Remote sync

Use `.agit/config.json` to define one or more named S3-compatible remotes:

```json
{
  "version": 1,
  "remotes": [
    {
      "name": "backup",
      "endpoint": "https://s3.example.com",
      "bucket": "agit-backups",
      "region": "us-east-1",
      "prefix": "personal/agengit",
      "access_key_env": "AGIT_REMOTE_ACCESS_KEY",
      "secret_key_env": "AGIT_REMOTE_SECRET_KEY",
      "session_token_env": "AGIT_REMOTE_SESSION_TOKEN",
      "encryption_secret_env": "AGIT_REMOTE_ENCRYPTION_SECRET"
    }
  ]
}
```

Then sync with:

```sh
agit push
agit pull
```

`agit push` runs a local fsck preflight and refuses plaintext uploads when
`agit privacy scan` finds sensitive content unless the remote config provides
`encryption_secret_env` or you explicitly pass `--allow-sensitive`. When
configured, remote objects are encrypted client-side before upload and verified
against their plaintext BLAKE3 hash on pull.

The remote backend is intentionally dumb-server style: objects are stored by
hash and refs are stored as plain text. Ref updates are best-effort, so racing
writers to the same remote ref can still conflict.

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

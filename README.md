# agit

AI agent version control — captures your AI coding-agent sessions (prompts, tool calls, responses, workspace snapshots, and per-line blame) in a content-addressed, queryable object store.

Inspired by [`regent-vcs/re_gent`](https://github.com/regent-vcs/re_gent). Written in [Zig](https://ziglang.org/) 0.16.

## Status

⚠️ **Work in progress.** This project is in early implementation. No stable API yet.

## Supported agents (planned v1)

| Agent | Integration |
|---|---|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | Hook commands (`agit claude-hook`) |
| [OpenAI Codex CLI](https://github.com/openai/codex) | Hook commands (`agit codex-hook`) |
| [Google Gemini CLI](https://github.com/google-gemini/gemini-cli) | Hook commands (`agit gemini-hook`) |
| [Pi](https://pi.dev) | Filesystem observer (`agit pi-watch`) |
| [GitHub Copilot CLI](https://docs.github.com/en/copilot/using-github-copilot/using-github-copilot-in-the-command-line) | Filesystem observer (`agit copilot-watch`) |

## Install

### Binary (recommended)

Download the latest release from the [releases page](https://github.com/matt-riley/agengit/releases):

| Platform | Archive |
|---|---|
| Linux x86_64 | `agit-x86_64-linux.tar.gz` |
| Linux aarch64 | `agit-aarch64-linux.tar.gz` |
| macOS arm64 | `agit-aarch64-macos.tar.gz` |
| macOS x86_64 | `agit-x86_64-macos.tar.gz` |
| Windows x86_64 | `agit-x86_64-windows.zip` |

```sh
# Linux / macOS example
tar -xzf agit-x86_64-linux.tar.gz
sudo mv agit /usr/local/bin/
agit version
```

### Build from source

```sh
git clone https://github.com/matt-riley/agengit
cd agengit
zig build -Doptimize=ReleaseSafe
# binary is at ./zig-out/bin/agit
```

## Usage

```sh
# Set up agit in the current repository and configure all detected agents
agit init

# Check your configuration and store health
agit doctor

# List all recorded sessions
agit sessions

# Show the step history of a session
agit log <session-id>

# Show details of a specific step
agit show <step-hash>

# Show per-line blame for a file
agit blame src/main.zig

# Print a raw object
agit cat <hash>

# Remove agit hooks from all agent configs (preserves user content)
agit uninstall
```

## Store layout

agit stores everything in `.agit/` inside your repository root:

```
.agit/
├── config.json          # Repository configuration
├── objects/             # Content-addressed blobs, trees, steps, blame maps
├── refs/
│   └── sessions/        # Per-session DAG ref pointers
├── blame/               # Per-file line attribution
├── index.db             # SQLite query index
└── log/
    └── hook-error.log   # Hook error log (never crashes the agent)
```

The store format is **not byte-compatible** with `re_gent` in v1. API/behavior compatibility is the goal; byte compatibility will be addressed in a future migration plan.

## License

GNU General Public License v3.0 — see [LICENSE](./LICENSE).

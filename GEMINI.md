# AgenGit (agit) - Project Overview

`agit` is a black-box recorder for AI coding sessions. It records prompts, tool calls, and workspace snapshots for agents like Claude Code, OpenAI Codex CLI, and Google Gemini CLI. It stores this data in a local `.agit/` directory at the repository root, allowing users to inspect what an agent did between commits.

## Technology Stack

- **Language:** Zig (0.16.0)
- **Dependencies:**
  - `clap`: Command-line argument parsing.
  - `zqlite`: SQLite integration for indexing.
  - `blake3`: Content-addressing (via BLAKE3 hashing).

## Project Architecture

- **`src/main.zig`**: Entry point and CLI command routing.
- **`src/cli/`**: Implementation of individual CLI commands (`init`, `status`, `log`, etc.).
- **`src/store/`**: Core logic for the object store, refs, snapshots, and indexing.
- **`src/hook.zig`**: Infrastructure for reading agent hook payloads and reporting failures.
- **`src/recorder.zig`**: Orchestrates recording session steps and workspace snapshots.
- **`.agit/` Store Structure**:
  - `objects/`: Content-addressed blobs, trees, and steps (BLAKE3).
  - `refs/`: Mutable pointers to session heads.
  - `index.db`: SQLite database for fast querying (rebuildable via `agit reindex`).
  - `log/`: Hook failure logs (`hook-error.log`).

## Building and Running

### Prerequisites
- Zig 0.16.0

### Build Commands
- **Build executable:** `zig build -Doptimize=ReleaseSafe`
- **Run agit:** `zig build run -- [args]`

### Testing and Quality
- **Unit tests:** `zig build test`
- **End-to-end tests:** `zig build test-e2e`
- **Update E2E golden files:** `AGIT_UPDATE_GOLDEN=1 zig build test-e2e`
- **Benchmark durable writes:** `zig build bench-durable`
- **Format check:** `zig build check-fmt`
- **Auto-format:** `zig build fmt`

## Key CLI Commands

- `agit init`: Configures agent hooks (Claude, Codex, Gemini) in their respective user settings.
- `agit status`: Displays current repository state and store health.
- `agit sessions`: Lists captured agent sessions.
- `agit log [session]`: Shows step history for a session.
- `agit show <hash>`: Inspects a specific recorded step.
- `agit doctor`: Validates hook configurations and store integrity.
- `agit reindex`: Rebuilds the SQLite index from the object store.
- `agit uninstall`: Removes hooks from agent configurations.

## Development Conventions

- **Hook Safety:** Hooks must be non-blocking. If capture fails, they log to `.agit/log/hook-error.log` and mirror to stderr but exit with status 0 to avoid disrupting the agent's work.
- **Durable Writes:** Atomic writes and directory fsyncs are used by default.
- **Environment Variables:**
  - `AGIT_FSYNC=0`: Disables directory fsync (use for tests or benchmarks).
  - `AGIT_UPDATE_GOLDEN=1`: Updates golden files during E2E tests.
- **Snapshots:** Conservative filtering is applied to snapshots (skipping `.git`, `.agit`, dependencies, and large/binary files). Custom rules can be added to `.agitignore`.
- **Documentation:** Design decisions are recorded in ADRs under `docs/adr/`.

## Design Records (ADRs)
Refer to the `docs/adr/` directory for detailed design history, including:
- [001: Store directory](docs/adr/001-store-directory.md)
- [003: Hook process model](docs/adr/003-hook-process-model.md)
- [004: Snapshot policy](docs/adr/004-snapshot-policy.md)
- [006: Crash-safe agent config writes](docs/adr/006-crash-safe-agent-config-writes.md)

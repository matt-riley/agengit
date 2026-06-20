# Plan 006: Add project AGENTS.md for agent contributors

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 07fffa1..HEAD -- CLAUDE.md AGENTS.md`
> If `CLAUDE.md` changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx
- **Planned at**: commit `07fffa1`, 2026-06-20

## Why this matters

This repository helps record AI-agent activity, yet agent contributors working
on it lack project-specific instructions. A project `AGENTS.md` gives coding
agents the build commands, conventions, architecture overview, and domain
language they need to contribute effectively. Pi loads `AGENTS.md` at startup
(along with `CLAUDE.md`), and other agents use it as context. The file already
exists as `CLAUDE.md` with solid project documentation — `AGENTS.md` should be a
near-identical copy with minor adaptations, or a slim router pointing at
`CLAUDE.md`.

## Current state

- `CLAUDE.md` exists at the repo root with comprehensive build commands,
  architecture overview, testing layout, coding conventions, ADR references,
  commit style, and environment variables.
- `GEMINI.md` exists at the repo root (content unknown, likely a Gemini-specific
  variant).
- `AGENTS.md` does NOT exist. Pi loads `AGENTS.md` from the cwd and parent
  directories by default. Without it, pi (and other agents that follow the
  Agent Skills conventions) lack project context when working on this repo.

## Commands you will need

| Purpose   | Command                  | Expected on success |
|-----------|--------------------------|---------------------|
| Verify    | `zig build check-fmt`    | exit 0              |

## Scope

**In scope** (the only files you may touch):
- `AGENTS.md` (create)

**Out of scope** (do NOT touch):
- `CLAUDE.md` — remains the primary Claude Code reference; `AGENTS.md` may
  reference it or duplicate its content.
- `GEMINI.md` — remains as-is.
- Any source code changes.

## Git workflow

- Branch: `advisor/006-agents-md`
- Commit: `docs: add AGENTS.md for agent contributor guidance`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `AGENTS.md`

Create `AGENTS.md` at the repo root. The file should contain either:

**Option A (recommended — slim router)**: A short file that tells agents to read
`CLAUDE.md` for project context, plus any pi-specific additions:

```markdown
# AGENTS.md

This file provides guidance to coding agents when working with code in this
repository.

## Project context

Read `CLAUDE.md` for the full project reference: build commands, architecture,
testing layout, coding conventions, ADR references, commit style, and
environment variables. The `AGENTS.md` file supplements it with
standards-convention metadata.

## Agent skills reference

This project follows the [Agent Skills standard](https://agentskills.io).
Project skills live in `.agents/skills/`. Agent-installed skills live in
`~/.agents/skills/`. See the `improve` skill for the codebase audit and
implementation planning workflow.

## Repository guidelines

These are the same rules in `CLAUDE.md`. They are repeated here because
`AGENTS.md` is the standards-convention entry point:

- Follow `zig fmt`; do not hand-align against it.
- New subcommands go in `src/cli/<command>.zig`; store primitives in `src/store/`.
- Names: `snake_case` for locals/functions, `PascalCase` for types.
- When changing CLI behavior, keep `src/main.zig` usage text, README examples,
  and generated docs in sync. Run `zig build docgen`.
- Run `zig build check` before submitting; run `zig build test-e2e` when
  behavior changes.
- Use Conventional Commit prefixes: `feat:`, `fix:`, `docs:`, `ci:`, `chore:`.
```

Use the slim router approach — `CLAUDE.md` is already comprehensive and keeping
a single source of truth reduces drift. The `AGENTS.md` should add
standards-convention metadata (Agent Skills reference) and repeat the key
repository guidelines that the project instructions at the top of the repo
wiring instruct agents to look for.

**Verify**: `zig build check-fmt` → exit 0. Also confirm the file is non-empty:
`test -s AGENTS.md` → exit 0.

## Test plan

No code changes; no test changes needed. Verify formatting only.

## Done criteria

- [ ] `AGENTS.md` exists at repo root with non-empty content
- [ ] `zig build check-fmt` exits 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated to DONE

## STOP conditions

Stop and report back (do not improvise) if:

- `CLAUDE.md` has changed since this plan was written (git log shows new
  commits touching it).
- `GEMINI.md` content significantly differs from `CLAUDE.md` in a way that
  would make the `AGENTS.md` content misleading (e.g., different build
  commands).

## Maintenance notes

- When `CLAUDE.md` is updated, check whether `AGENTS.md` needs corresponding
  updates (especially the repeated repository guidelines).
- If the project adopts a different agent instructions model (e.g., per-path
  AGENTS.md files), revisit whether this file should be split.

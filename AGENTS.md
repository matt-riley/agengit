# AGENTS.md

This file provides guidance to coding agents working in this repository.

## Project context

Read `CLAUDE.md` for the full project reference (build/test commands, architecture, testing layout, conventions, ADR expectations, and commit style). `AGENTS.md` is a slim router plus high-signal reminders.

## Agent skills reference

This repo follows the [Agent Skills standard](https://agentskills.io).

- Project skills: `.agents/skills/`
- User-installed skills: `~/.agents/skills/`
- Recommended workflow: use the `improve` skill for audits and implementation planning.

## Key repository guidelines

- Use Zig `0.16.0`.
- Follow `zig fmt`; do not hand-format against it.
- Keep module placement consistent: commands in `src/cli/`, store primitives in `src/store/`, helpers in `src/util/`.
- Naming: `snake_case` for functions/locals, `PascalCase` for types, lowercase filenames.
- When behavior changes, keep CLI/help/docs/tests aligned (especially `src/main.zig`, README examples, and relevant tests/goldens).
- Prefer `zig build check` for local verification; run `zig build test-e2e` when observable CLI/recorder behavior changes.
- Use Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`).

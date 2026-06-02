# ADR 040: Install Copilot capture through a generated extension

**Status:** Implemented
**Date:** 2026-06-02

## Context

The original Copilot integration in `agit` assumed a standalone
`~/.copilot/hooks.json` file with command-hook entries, mirroring the Codex
shape. On current Copilot CLI builds in active use, that contract has drifted:

- there is no standalone `~/.copilot/hooks.json` on disk,
- the CLI documents inline `hooks` config instead of a dedicated hook file,
- the public, stable integration surface is the `~/.copilot/extensions/`
  directory plus the `@github/copilot-sdk/extension` lifecycle hooks.

That drift breaks `agit init`, `agit doctor`, and real capture because `agit`
keeps writing and checking a file the live CLI does not read.

## Decision

Switch Copilot installation from JSON hook config to a generated extension at:

`~/.copilot/extensions/agit-recorder/extension.mjs`

The extension subscribes to Copilot's public lifecycle hooks:

- `onUserPromptSubmitted`
- `onPostToolUse`
- `onAgentStop`

It stays fail-open and shells out to `agit copilot-hook` with a normalized JSON
payload matching the existing `src/hook/adapters/copilot.zig` contract. This
keeps recorder/storage logic unchanged while moving the install surface onto the
supported Copilot API.

## Consequences

- `agit init` writes a generated Copilot extension instead of `hooks.json`.
- `agit doctor` validates the generated extension file and its embedded binary
  path, just like Pi's extension install.
- `agit uninstall` removes the generated extension and still tolerates any old
  legacy `~/.copilot/hooks.json` file from earlier builds.
- The Copilot hook adapter remains useful because the extension emits the same
  normalized payload shape as before.

## Implementation Notes

- Copilot is now `install_kind = .js_extension` in
  `src/cli/init_plan.zig`.
- The generated source lives in `src/cli/copilot_extension.zig`.
- The extension keeps its own monotonic `turn_id` / `tool_use_id` fallback so
  recorded turns remain groupable even though the public Copilot hook inputs do
  not expose the older hook-runner event ids.

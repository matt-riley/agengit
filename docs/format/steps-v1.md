# Steps v1

`agit steps --json` returns all steps in a session with full step data and
per-step diffs in a single JSON envelope.

## JSON envelope

All `agit steps` output is wrapped in the standard CLI JSON envelope
(`cli-json-v1`). The `command` field is `"steps"`.

```json
{
  "schema_version": "cli-json-v1",
  "command": "steps",
  "data": {
    "origin": "codex",
    "session_id": "session-abc",
    "steps": [
      {
        "hash": "<64-hex BLAKE3>",
        "turn_id": "turn-1",
        "timestamp": 1700000000000,
        "model": "claude-sonnet-4",
        "outcome": "success",
        "git_commit": "<40-hex SHA-1 or null>",
        "git_branch": "main",
        "git_dirty": false,
        "step": {
          "messages": [{ "role": "user", "content": "Add a feature" }],
          "tool_calls": [{ "tool_name": "bash", "args": "zig build test", "result": "All tests passed" }]
        },
        "diff": {
          "changes": [
            { "kind": "added", "path": "src/main.zig", "old_blob": null, "new_blob": "<64-hex>", "old_size": null, "new_size": 1234 }
          ],
          "counts": { "added": 1, "modified": 0, "deleted": 0, "unchanged": 4 }
        }
      }
    ]
  }
}
```

## Flags

### `--json` (required)

The `steps` command only supports JSON output. Omitting `--json` produces an
error diagnostic.

### `--include-step-objects`

Include full step message and tool_call bodies in each step entry. Without
this flag, only step metadata (hash, turn_id, timestamp, model, outcome,
git_commit, git_branch, git_dirty) is included — the `step` and `diff` fields
are omitted.

### `--no-diffs`

Skip per-step diff computation. By default, diffs are included for each step
when `--include-step-objects` is set.

## Performance notes

A session with N steps requires a single `agit steps --json` call to fetch all
step data and diffs. This replaces the previous N+1 pattern of calling
`agit log --json` followed by `agit show --json` and `agit diff --json` for
each step.

The `--include-step-objects` flag controls whether message/tool_call bodies
are loaded. Use metadata-only queries for fast session browsing and
include-step-objects only when message content is needed.

Diffs are computed by comparing each step's captured tree against its
parent's tree, so `--include-diffs` (default) requires loading both step and
parent objects.

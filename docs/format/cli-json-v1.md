# CLI JSON v1

`agit` commands that support machine-readable output emit a shared JSON envelope:

```json
{
  "schema_version": "cli-json-v1",
  "command": "status",
  "data": {}
}
```

## Envelope

- `schema_version` — currently always `cli-json-v1`
- `command` — the command that produced the payload
- `data` — command-specific response data

## Diagnostics

Diagnostics appear inside `data` and use stable codes:

```json
{
  "code": "store_not_found",
  "message": "Not an agit repository.",
  "hint": "Run `agit init` from the repository root to start recording.",
  "path": ".",
  "hash": null,
  "candidates": null
}
```

- `code` — stable machine-readable identifier
- `message` — human-readable summary
- `hint` — optional next step or extra detail
- `path` — optional related file/path
- `hash` — optional related object hash or prefix
- `candidates` — optional candidate hashes when a short prefix is ambiguous

Doctor checks extend the same shape with a `status` field whose values are
`ok`, `info`, `warn`, or `error`.

## Commands

`cli-json-v1` is currently supported by:

- `agit status --json`
- `agit sessions --json`
- `agit log --json`
- `agit show --json <hash>`
- `agit recall --json [QUERY]`
- `agit eval --json`
- `agit doctor --json`
- `agit fsck --json`
- `agit export --json <path>`
- `agit import --json <path>`

## Timeline / recall rows

List-view row payloads emitted by the envelope (e.g. `between --json`, and the
`step` events emitted by `watch --json`, plus `recall --json` matches) carry a
`preview` field:

```json
{
  "hash": "<64-char step hash>",
  "origin": "codex",
  "session_id": "abc123",
  "turn_id": "turn-1",
  "timestamp": 1769600000000,
  "preview": "first user message of the turn, collapsed and truncated to 96..."
}
```

- `preview` — the list-view row preview string, computed once at finalize time
  and stored in the index. Identical to the on-screen preview a list command
  renders for the same step: the first non-empty user message, else the first
  assistant message, else the first tool result/args/name, else
  `(no preview)`, with whitespace collapsed and truncated to 96 bytes (the
  multi-byte ellipsis appended at the truncation point may extend the output
  slightly). Stored unredacted; viewers apply redaction at display
  time via their own privacy config. `null` only for steps recorded before this
  column was added until `agit reindex` backfills them.

## Eval hash

`agit eval --json` includes an `eval_hash` field in `data` — the 64-char hex
BLAKE3 hash of the persisted eval object written to `.agit/objects/`.

`agit recall --json` supports `--judged good|bad|mixed` to filter results
to sessions whose latest eval classification matches.

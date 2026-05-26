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
- `agit doctor --json`
- `agit fsck --json`

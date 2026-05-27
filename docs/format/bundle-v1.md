# Portable bundle v1

Portable bundles are directory exports produced by `agit export` and consumed by
`agit import`. They are meant for offline sharing, archival, and migration
without copying mutable `.agit/` internals.

## Goals

- export only canonical session refs and reachable objects,
- exclude rebuildable or host-local state such as `index.db`, logs, locks, and
  staging files,
- validate bundle contents before import writes anything,
- keep v1 dependency-light by using a plain directory layout.

## Directory layout

`agit export <path>` writes a directory with this shape:

```text
bundle/
  manifest.json
  objects/
    0a/
      bcdef...            # loose object bytes named by BLAKE3 hash
  refs/
    sessions/
      636c61756465/
        736573732d313233
  privacy-report.json     # optional; only when export findings exist and --allow-sensitive is used
```

### Notes

- Bundles always store objects as loose `objects/<2-hex>/<62-hex>` files even if
  the source store currently keeps them inside pack files. Export reads objects
  through the store abstraction and normalizes them into loose bundle entries.
- `refs/sessions/...` uses the same hex-encoded path layout as the local store.
- `manifest.json` is required.
- `privacy-report.json` is optional and absent for clean exports.
- `index.db`, `tmp/`, `log/`, `*.lock`, and other mutable `.agit/` internals are
  never bundled.

## Manifest

`manifest.json` is UTF-8 JSON with this shape:

```json
{
  "bundle_format": "agit-bundle-v1",
  "bundle_id": "4d4f8f7a...",
  "producer_version": "1.15.0",
  "created_at_ms": 1780000000000,
  "repository_hint": "owner/repo",
  "filters": {
    "origin": "claude",
    "session": "claude/session-123",
    "since": "2026-05-01",
    "until": "2026-05-31"
  },
  "object_schema_versions": {
    "tree": 1,
    "step": 1,
    "blame": 1
  },
  "refs": [
    {
      "path": "refs/sessions/636c61756465/73657373696f6e2d313233",
      "origin": "claude",
      "session_id": "session-123",
      "head_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  ],
  "objects": [
    {
      "hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "kind": "step",
      "size": 512,
      "path": "objects/aa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
  ],
  "privacy": {
    "clean": true,
    "findings": 0,
    "report_path": null
  },
  "encryption": null
}
```

### Required fields

- `bundle_format` — must be `agit-bundle-v1`
- `bundle_id` — opaque lowercase hex identifier for this bundle; import uses the
  first 12 hex characters when it must namespace a conflicting session ref
- `producer_version` — `agit` version that wrote the bundle
- `created_at_ms` — Unix epoch milliseconds
- `repository_hint` — repository name when known, otherwise `null`
- `filters` — export filter inputs; fields may be `null`
- `object_schema_versions` — object schema versions supported by the exporter
- `refs` — exported session refs
- `objects` — bundled object inventory with hash, kind, size, and relative path
- `privacy` — privacy preflight summary
- `encryption` — reserved for future encrypted bundles; v1 plaintext bundles
  must set this to `null`

## Export selection rules

- With no filters, export all reachable sessions from `refs/sessions/`.
- `--origin <name>` keeps only sessions from one origin.
- `--session <origin/session-id>` keeps one session. v1 requires the
  disambiguated `origin/session-id` form.
- `--since YYYY-MM-DD` and `--until YYYY-MM-DD` filter sessions by step
  timestamps, but they still export the full reachable chain for each selected
  session. A session is selected when at least one reachable step falls inside
  the requested window.

This full-session rule avoids bundles whose steps reference missing parent
objects.

## Reachability rules

For each exported ref, the bundle must include:

- the head step,
- every parent step reachable from that head,
- every tree referenced by those steps,
- every blob referenced by those trees.

Objects are deduplicated across refs by hash.

## Export preflights

Before writing a bundle, `agit export` must:

1. run the same integrity scan used by `agit fsck` and fail on any errors,
2. run the privacy scan against the selected sessions only,
3. refuse plaintext export when privacy findings exist unless
   `--allow-sensitive` is present.

When `--allow-sensitive` is used and findings exist, export writes
`privacy-report.json` and records its relative path in
`manifest.json.privacy.report_path`.

## Import rules

`agit import <path>` must validate the bundle before it writes any local data.
Validation includes:

- required manifest fields and `bundle_format`,
- every manifest object entry has a matching file,
- each bundled object's BLAKE3 hash and size match the manifest,
- every imported step/tree reference points to another bundled object,
- every exported ref head hash is present in the object set.

After validation succeeds, import writes missing objects idempotently and then
applies refs.

## Ref conflict handling

For each imported ref:

- if the local canonical session ref does not exist, import writes it at the
  canonical path,
- if the local canonical session ref already points at the same hash, import
  leaves it unchanged,
- if the local canonical session ref points at a different hash, import does not
  overwrite it by default.

By default, conflicting refs are written under the normal `refs/sessions/`
namespace using the exported origin and a namespaced session id:

```text
<original-session-id>@import-<bundle_id[0..12]>
```

This keeps imported conflict sessions visible to existing `agit sessions`,
`agit log`, and `agit show` flows without inventing a second ref tree that the
current indexer would ignore.

`--replace-ref <origin/session-id>` may be repeated to allow overwrite of named
canonical refs from the bundle. v1 does not support a blanket "replace all"
flag.

## Index handling

- Bundles never contain `index.db`, WAL, or SHM files.
- Import completes by rebuilding the local SQLite index from object/ref truth
  after object and ref writes finish.

## Compatibility notes

- v1 bundles are plaintext directories only.
- Future versions may add tar/zip containers, compression, or encryption
  metadata, but they must not silently change the meaning of v1 fields.

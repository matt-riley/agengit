# Blame v1

`agit blame` answers "which agent step last changed this line of this file?".
It is the agent-history analogue of `git blame`.

## Blame object

A `blame` object is a content-addressed JSON object (BLAKE3, stored under
`.agit/objects/`) that maps every line of one file to the step that last
changed it:

```json
{
  "type": "blame",
  "path": "src/main.zig",
  "lines": [
    { "step": "<64-hex step hash>" },
    { "step": "<64-hex step hash>" }
  ]
}
```

- `path` — workspace-relative, `/`-normalized file path.
- `lines[i].step` — the 64-char lowercase hex hash of the step that last
  changed line `i` (0-based). Repeated step hashes are deduplicated in memory
  but serialized per line.

Lines are derived with a single canonical splitter (`splitLines`): split on
`\n`, trim a trailing `\r`. A trailing `\n` yields a final empty line. Finalize,
reindex, and rendering all use the same splitter so a blame object's line count
always matches the file content it describes.

## Recording

Blame is recorded incrementally at finalize, after the step object is committed
(the step hash is then known; the step object itself does not reference any
blame object). For each captured text file whose content changed:

1. The new content is diffed (LCS, the ADR 016 diff machinery) against the
   previous recorded version of that file.
2. Unchanged lines inherit their prior attribution; inserted/changed lines are
   attributed to the new step.
3. A new `blame` object is written and a `blame_maps` row is recorded.

Skipped (never blamed): binary files, files over the large-file cap
(`AGIT_MAX_FILE_BYTES`), and `metadata_only` snapshot placeholders.

### Global continuity

Because every session records snapshots of the **same** working tree, the
"previous version" of a file is the most recent blame for that path across **all
sessions**, ordered by finalize timestamp. Step timestamps are made strictly
monotonic at finalize (under the global `gc.lock`), so the ordering is a
canonical total order that `agit reindex` reproduces exactly.

## Linkage (`blame_maps`)

The link from a file path to its latest blame object lives in the rebuildable
SQLite index, not in the canonical objects:

| column          | meaning                                            |
| --------------- | -------------------------------------------------- |
| `session_origin`| origin that recorded the step                      |
| `session_id`    | session that recorded the step                     |
| `path`          | workspace-relative file path                       |
| `step_hash`     | step that produced this blame                      |
| `blame_hash`    | the `blame` object hash                            |
| `blob_hash`     | the file's content blob at this step               |
| `timestamp`     | the step's (monotonic) finalize timestamp          |

- Latest blame for a path = row with greatest `(timestamp, step_hash)`.
- `agit blame --step <H>` selects the latest row at or before `H`.

`agit reindex` clears `blame_maps` and replays all steps in `(timestamp, hash)`
order, reproducing identical blame. Because the linkage is index-only, run
`agit reindex` before `agit gc` if `index.db` was lost — gc treats blame objects
referenced by `blame_maps` as reachable.

## Fail-open and crash safety

Blame recording never breaks a finalize. The `blame_needs_reindex` flag is set
durably **before** any blame is written for a step, and cleared only after that
step's `blame_maps` rows commit successfully. Each step's rows are inserted in a
single transaction. As a result:

- A blame error rolls back the rows and leaves the flag set.
- A crash between the step commit and blame completion also leaves the flag set.

While the flag is set, finalize stops recording incremental blame (existing
blame stays valid but stale) until `agit reindex` rebuilds everything and clears
it. Finalize also sets the flag if the monotonic timestamp counter cannot be
read or advanced, so a non-monotonic timestamp is never written into the chain.
`agit reindex` re-sets the flag if any step fails to replay, so a partial
rebuild is never reported as healthy.

## v1 limitations

- **Renames** are treated as delete + add and break attribution continuity.
- **Deleted then recreated** files may inherit stale blame (no tombstones in
  v1).
- Blame is recorded only for text files within the size cap.

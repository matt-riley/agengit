# ADR 034: Snapshot restore

**Status:** Implemented
**Date:** 2026-05-31

## Context

`agit` captures full content-addressed workspace snapshots on every finalized
step (ADR 004), but there is no way to read those snapshots back onto disk. The
store is currently write-and-inspect only: `show`, `diff`, `cat`, and `blame`
let a user *look* at captured content, but not *recover* it.

This leaves obvious value on the table. When an agent deletes or clobbers a file
the user wanted, the correct version often already sits in a recorded tree. The
recorder has captured exactly the bytes needed, yet the user must reconstruct
them by hand from `agit cat`. A first-class restore turns agit from a forensic
log into a recovery safety net.

## Decision

Add `agit restore` to materialize recorded snapshot content back into the
working tree, with explicit, non-surprising overwrite semantics.

1. **Restore scope:** `agit restore <step> [-- <path>...]` restores either the
   whole captured tree for a step or only the listed paths from it. Default is
   path-scoped restore is encouraged; whole-tree restore requires `--all`.
2. **Safety first:** restore never overwrites existing files unless `--force`
   is given. Without `--force`, existing target files are skipped and reported.
   A `--dry-run` flag prints the planned writes without touching disk.
3. **Out-of-tree protection:** restored paths are validated to stay within the
   workspace root; symlink and `..` traversal in captured paths are rejected.
4. **Atomic writes:** each restored file is written via the existing
   `createFileAtomic` + fsync path (ADR 008) so a crash cannot leave a partial
   file in place of the user's data.
5. **Privacy interaction:** restore writes real captured bytes by design, so it
   is a content-revealing operation. It honors the same access path as `cat`
   and warns when redaction policy (ADR 026) would otherwise mask the content.
6. **No Git side effects:** restore only writes files; it never stages,
   commits, or touches `.git/`.

## Plan

1. Add a tree-walking helper that yields `(path, blob hash, mode)` for a step
   tree, reusing the readers added in ADR 030.
2. Add reusable path-safety validation (reject absolute, `.agit`, `..`, and
   symlink-escaping paths).
3. Implement `cli/restore.zig` with `--all`, `--force`, `--dry-run`, and path
   filters.
4. Reuse atomic write + directory fsync helpers from `src/util/fs.zig`.
5. Emit a structured `cli-json-v1` summary of restored, skipped, and failed
   paths for `--json`.
6. Add README examples and command docs after implementation.

## Testing

- E2E test: record a step, delete a file on disk, `agit restore <step> -- file`
  recovers it byte-for-byte.
- E2E test: restore without `--force` skips an existing file and reports it;
  with `--force` it overwrites atomically.
- E2E test: `--dry-run` prints planned writes and changes nothing on disk.
- Security test: a crafted tree with a `..` path is rejected without writing
  outside the workspace.
- Unit test: tree-walk helper yields correct paths and modes for nested trees.
- Golden test covers human and `--json` restore summaries.

## Risks and tradeoffs

- Restore is destructive when `--force` is used. Defaults must be conservative,
  and dry-run must be cheap and obvious.
- Restoring a whole tree could resurrect files the user intentionally deleted.
  Requiring `--all` and reporting every write reduces surprise.
- Snapshot entries currently record regular files only (`mode = "file"`), so
  executable-bit restoration remains deferred until snapshots capture that
  metadata.

## Consequences

- The captured snapshots gain a recovery use case, not just inspection.
- Users get an "undo the agent" path without leaving agit.
- Future features (interactive restore, restore-to-branch) can build on the
  same tree-walk and safety primitives.

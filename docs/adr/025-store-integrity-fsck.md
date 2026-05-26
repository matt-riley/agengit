# ADR 025: Store integrity verification with `agit fsck`

**Status:** Implemented
**Date:** 2026-05-25

## Context

The content-addressed object store is the canonical history. SQLite is
rebuildable, refs are mutable session heads, and commands such as `reindex`
already tolerate some malformed data by skipping objects they cannot parse.

That is useful for resilience, but it leaves users without a deliberate answer
to these questions:

- Does every object file match its BLAKE3 path?
- Do step objects point at existing tree objects?
- Do tree objects point at existing blob objects?
- Do refs point at valid step objects?
- Does `index.db` agree with refs and reachable step objects?

Garbage collection, packfiles, export/import, and remote synchronization all
increase the cost of trusting a partially corrupt store.

## Decision

Add a read-only `agit fsck` command that verifies store integrity without
modifying data by default.

`agit fsck` checks:

1. **Object path integrity:** every loose object path under
   `.agit/objects/<prefix>/<suffix>` is valid hex and its content hashes to the
   path.
2. **Object schema:** JSON objects with `type: "tree"`, `type: "step"`, or
   `type: "blame"` parse according to the supported schema. Unknown JSON objects
   are reported as warnings unless referenced.
3. **Reachability links:** step parents, step trees, tree blobs, and blame step
   references point at existing objects.
4. **Ref health:** every session ref contains exactly one valid hash and points
   at a step object.
5. **Index consistency:** `sessions`, `steps`, `messages`, and `tool_calls`
   match the reachable step graph. Drift is reported with a suggested
   `agit reindex` command.
6. **Mutable-area health:** stale locks, corrupt staging files, and quarantined
   staging dumps are summarized, but not deleted.

The command exits non-zero for corruption, zero for a healthy store, and zero
with warnings for recoverable drift. It supports `--json` for tooling.

Repair remains explicit:

- `agit fsck --reindex` may rebuild only `index.db`.
- destructive pruning remains owned by `agit gc` (ADR 020).
- quarantining corrupt object files requires an explicit future flag and must
  never happen during plain `fsck`.

## Plan

1. Add `src/cli/fsck.zig` and wire it into `src/main.zig`.
2. Add `src/store/integrity.zig` for graph traversal and object validation.
3. Reuse hash parsing and object readers from `src/store/object.zig`, but add a
   raw read path that can validate object bytes before schema parsing.
4. Teach `doctor` to recommend `agit fsck` when it sees store drift, without
   running the full traversal by default.
5. Add `--json` output with stable diagnostic codes.

## Testing

- Unit tests for object hash mismatch, invalid object path, missing tree blob,
  missing step parent, corrupt ref, and index drift.
- E2E test: record a valid session, run `agit fsck`, assert success.
- E2E test: mutate one object byte, run `agit fsck`, assert non-zero and a
  specific diagnostic code.
- E2E test: delete index rows, run `agit fsck`, assert warning plus
  `agit fsck --reindex` repairs the index.

## Risks and tradeoffs

- Full graph traversal can be slow on large stores. The first version favors
  correctness and clear output; later versions can use the object cache from
  ADR 015.
- Some historical objects may parse with older schemas. The validator must
  understand supported versions before it starts flagging old stores as broken.
- A repair flag that does too much would risk data loss. Keep repair modes
  narrow and explicit.

## Consequences

- Users get a trustworthy way to distinguish harmless index drift from real
  store corruption.
- `gc`, packfiles, export/import, and remote sync gain a preflight they can
  depend on.
- Support/debugging becomes easier because integrity failures have stable codes
  instead of ad-hoc parse errors.

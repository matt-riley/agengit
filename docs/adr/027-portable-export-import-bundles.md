# ADR 027: Portable export and import bundles

**Status:** Proposed
**Date:** 2026-05-25

## Context

Remote synchronization (ADR 023) covers durable multi-machine backup, but users
also need one-off portable bundles:

- attach a session history to a bug report,
- hand an agent trace to a teammate for review,
- archive a local session before pruning or changing machines,
- migrate from one store path to another without copying `.agit/` internals.

Copying `.agit/` directly is the wrong boundary. It includes rebuildable
`index.db`, locks, temporary staging, logs, and future backend-specific state.
It also has no manifest, no privacy preflight, and no compatibility story.

## Decision

Add `agit export` and `agit import` around a versioned bundle format.

1. **Bundle shape:** a bundle contains:
   - `manifest.json`,
   - reachable object files,
   - selected refs,
   - optional redaction report,
   - optional encryption metadata.
2. **Manifest fields:** include bundle format version, producer version,
   creation time, repository hint, exported refs, object hashes/sizes, privacy
   scan summary, and supported object schema versions.
3. **Export scope:** default to reachable objects from all refs. Support
   `--session`, `--origin`, `--since`, and `--until` filters.
4. **Safety:** export runs `agit fsck` preflight (ADR 025) and privacy scan
   preflight (ADR 026). Sensitive plaintext export requires
   `--allow-sensitive`.
5. **Import behavior:** validate manifest and object hashes before writing,
   import missing objects idempotently, then create refs under a conflict-safe
   namespace unless `--replace-ref` is provided.
6. **Index handling:** never export or import `index.db`; imports finish by
   running the reindex path for affected refs.

The first implementation may use an uncompressed directory or tar-compatible
container to keep dependencies low. Compression can be added after the manifest
contract is stable.

## Plan

1. Define `docs/format/bundle-v1.md` before implementation.
2. Add bundle manifest types and validation helpers under `src/store/bundle.zig`.
3. Implement `cli/export.zig` and `cli/import.zig`.
4. Reuse reachability traversal from `fsck` and privacy scanning from ADR 026.
5. Add README examples only after the commands are implemented and tested.

## Testing

- E2E test: record a session, export it, import into an empty repo, run
  `agit log` and `agit show` successfully.
- E2E test: import the same bundle twice and assert object writes and refs are
  idempotent.
- Corruption test: mutate a bundled object and assert import fails before
  writing anything.
- Conflict test: import a bundle whose ref already exists and assert it lands
  under the documented namespace unless `--replace-ref` is passed.
- Privacy test: export containing a synthetic secret is blocked without
  override or encryption.

## Risks and tradeoffs

- A bundle format becomes a compatibility promise. Keep v1 small and document
  what is intentionally excluded.
- Export filters can accidentally omit objects if reachability traversal is
  wrong. The fsck preflight and import validation reduce that risk.
- Encryption adds key-management questions. The bundle manifest should support
  encryption metadata, but v1 can require a local-only plaintext path until ADR
  026 and ADR 023 settle the key story.

## Consequences

- Users gain an offline sharing and archival path without copying mutable store
  internals.
- Remote sync is not the only portability mechanism.
- Future migration and compatibility tooling has a stable artifact to target.

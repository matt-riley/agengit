# ADR 023: Remote backup and synchronization (push/pull)

**Status:** Proposed
**Date:** 2026-05-25

## Context

`agit` records session history locally in `.agit/`. While this keeps the data
private and the hooks fast, it creates two problems:
1. **Durability:** If the local disk fails or the repository is deleted, the
   history is lost.
2. **Collaboration:** If a developer switches machines or wants to share an
   agent session with a teammate (e.g., for debugging a complex agent-driven
   refactor), there is no easy way to transfer the `.agit` data.

Git solves this with remotes. `agit` needs a similar mechanism.

## Decision

Implement `agit push` and `agit pull` to synchronize the object store and refs
with a remote backend:

1. **Remote Backend:** Initially support S3-compatible storage (AWS S3, Cloudflare
   R2, MinIO) as the primary remote backend.
2. **Transfer Model:** Use a "dumb server" model similar to early Git over HTTP.
   The remote stores objects by their BLAKE3 hash and refs as simple text files.
3. **Synchronization:**
   - `agit push` uploads all reachable objects and refs that are missing from
     the remote.
   - `agit pull` downloads missing objects and refs from the remote.
4. **Encryption:** Since `.agit` data often contains sensitive workspace code,
   all objects must be optionally encrypted locally (using a user-provided
   passphrase/key) before being uploaded.

## Plan

1. Add `src/store/remote.zig` to handle S3 API interactions (using a simple
   HTTP client, possibly `std.http.Client`).
2. Implement `cli/push.zig` and `cli/pull.zig`.
3. Add a `[remote "name"]` section to `.agit/config.json` (ADR 002) to store
   endpoint, bucket, and credential references.
4. Implement client-side encryption using Zig's `std.crypto`.

## Testing

- Integration test: push a session to a local MinIO instance, delete the
  local `.agit/`, pull it back, and assert that `agit log` and `agit show`
  work perfectly.
- Security test: verify that objects in the remote bucket are encrypted and
  cannot be read without the key.
- Performance test: measure the time to push a store with 10k objects.

## Risks and tradeoffs

- **Secret Management:** Managing S3 credentials and encryption keys adds
  complexity and security risk. We will follow best practices (env vars,
  keyrings).
- **Network Latency:** Pushing large stores can be slow. We will use
  concurrency (multiple upload workers) and only upload missing objects.
- **Dependency:** Adding an HTTP/S3 client increases the binary size and
  complexity.

## Consequences

- `agit` history becomes durable and portable.
- Teams can share "golden" agent sessions for onboarding or review.
- `agit` becomes a viable tool for professional, multi-machine workflows.

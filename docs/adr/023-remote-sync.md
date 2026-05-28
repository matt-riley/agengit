# ADR 023: Remote backup and synchronization (push/pull)

**Status:** Implemented
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

1. **Remote Backend:** Initially support S3-compatible storage (AWS S3,
  Cloudflare R2, MinIO, and path-style local test doubles).
2. **Transfer Model:** Use a dumb-server model similar to early Git over HTTP.
  The remote stores objects by BLAKE3 hash and refs as plain text files.
3. **Synchronization:**
  - `agit push` uploads locally reachable objects missing from the remote, then
    advances remote refs when they are unchanged or fast-forwardable.
  - `agit pull` downloads remote objects and refs, verifies object content, and
    reconciles the local index from ref/object truth.
4. **Encryption:** Object bodies may be encrypted client-side before upload when
  the remote config specifies `encryption_secret_env`. Plaintext uploads are
  blocked when the privacy scan finds sensitive content unless the operator
  explicitly overrides with `--allow-sensitive`.

  The envelope is versioned by an 8-byte magic. New encrypted writes use
  `AGITRM02`: the master key is derived from the secret with **Argon2id**
  (memory-hard) and a fixed domain-separating salt, then AES-256-GCM encrypts
  each object with a per-object nonce derived from the object hash. Legacy
  `AGITRM01` objects (master key = a single SHA-256 of the secret) remain
  decryptable so existing remotes keep working; they are never re-encrypted in
  place. Because objects are content-addressed, identical plaintext yields
  identical ciphertext — the scheme hides object *contents* from the remote but
  not *equality* of objects, and a per-deployment random salt cannot be stored
  without breaking dedup. Operators should still treat the encryption secret as
  high-entropy key material; Argon2id only raises, not eliminates, the cost of
  brute-forcing a weak passphrase.

## Implemented shape

Remote configuration lives in `.agit/config.json` under a `remotes` array:

```json
{
  "version": 1,
  "remotes": [
   {
     "name": "backup",
     "backend": "s3",
     "endpoint": "https://s3.example.com",
     "bucket": "agit-backups",
     "region": "us-east-1",
     "prefix": "team/repo",
     "access_key_env": "AGIT_REMOTE_ACCESS_KEY",
     "secret_key_env": "AGIT_REMOTE_SECRET_KEY",
     "session_token_env": "AGIT_REMOTE_SESSION_TOKEN",
     "encryption_secret_env": "AGIT_REMOTE_ENCRYPTION_SECRET"
   }
  ]
}
```

Implementation details:

- S3 requests use SigV4 signing against a path-style endpoint.
- Remote objects are stored under stable hash-derived keys and refs under a
  refs namespace.
- Encrypted object payloads use an explicit remote envelope and AES-256-GCM
  with associated data bound to the plaintext object hash.
- Pull verifies the decrypted or plaintext bytes still hash to the expected
  local object id before writing them.
- `agit push` and `agit pull` both refuse to run when the local store fails the
  fsck preflight.

## Testing

- Unit tests cover remote-envelope plaintext/encrypted round-trips.
- End-to-end tests exercise push/pull round-trip recovery, privacy-blocked
  plaintext push, and encrypted remote storage using a local fake S3 server.

## Risks and tradeoffs

- **Secret Management:** Managing S3 credentials and encryption keys adds
  complexity and security risk. We will follow best practices (env vars,
  keyrings).
- **Network Latency:** Pushing large stores can be slow. The current
  implementation avoids re-uploading existing objects but does not yet add
  concurrent transfer workers.
- **Dependency:** Adding an HTTP/S3 client increases the binary size and
  complexity.
- **Ref races:** S3 does not provide a remote compare-and-swap primitive for
  these text refs. Local push/pull protect against obvious divergence, but
  racing writers can still contend on the remote.

## Consequences

- `agit` history becomes durable and portable.
- Teams can share "golden" agent sessions for onboarding or review.
- `agit` becomes a viable tool for professional, multi-machine workflows.

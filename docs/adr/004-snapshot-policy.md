# ADR 004: Workspace Snapshot Policy

**Status:** Accepted

## Context

At each agent turn `agit` captures a snapshot of the project workspace to record what changed. Snapshots must be fast, safe (no secrets), and predictable in size.

## Decision

### Default ignored paths (always skipped, not configurable away)

```
.git/
.agit/
node_modules/
target/
.venv/
dist/
build/
.cache/
__pycache__/
*.pyc
```

### Default secret-file ignores (skipped unless explicitly included in `.agitignore`)

```
.env
.env.*
.envrc
*.pem
*.key
*.p12
*.pfx
id_rsa
id_ed25519
id_ecdsa
*.gpg
*.asc
```

### Hard limits

- Maximum file size per snapshot entry: **10 MB**. Files exceeding this are recorded as `{truncated: true, size: N}` metadata entries, not raw blobs.
- Binary files (detected by null-byte scan of first 8 KB): recorded as metadata only, no content blob stored.

### Incremental strategy (v1)

v1 uses **full snapshots** augmented with mtime/size cache metadata. The cache is stored alongside each `Tree` object and enables fast skipping of unchanged files in subsequent snapshots without requiring a file watcher.

Proper incremental snapshots using inotify/kqueue/FSEvents are deferred to a future phase. Zig 0.16 has no cross-platform file-watcher in the standard library.

### User override

`.agitignore` at the repository root uses `.gitignore`-compatible glob syntax to add project-specific ignores.

## Consequences

- No secrets or large binary files are ever stored in `.agit/objects/` by default.
- Snapshot latency is bounded by the per-file cap and default ignores for typical projects.
- Users must explicitly opt in to snapshot secret files via `.agitignore` negation patterns — `agit init` warns about this.

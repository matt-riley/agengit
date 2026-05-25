# ADR 004: Snapshot conservatively

**Status:** Accepted
**Editorial note:** Reworded on 2026-05-25 for clarity; the decision is unchanged.

## Context

`agit` snapshots the workspace so each agent step can point at the files it affected. Snapshots must be useful, quick enough for hook workflows, and careful around secrets and large files.

Perfect safety is not possible from filenames alone, but sensible defaults keep the treasure chest from filling with obvious dragons.

## Decision

Skip these paths by default:

```text
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

Skip common secret-looking files by default:

```text
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

Apply these hard limits:

- files larger than 10 MiB are skipped;
- binary files, detected by a null byte in the initial scan window, are skipped;
- symlinks are skipped.

Allow repository-specific ignore rules in `.agitignore`.

## Consequences

- Snapshots are bounded and avoid common generated directories.
- Secret filtering is best-effort and must not be described as a complete guarantee.
- Users should treat `.agit/` as private local history unless they have reviewed it.
- Future richer ignore behavior should preserve the safe defaults unless users explicitly opt in.

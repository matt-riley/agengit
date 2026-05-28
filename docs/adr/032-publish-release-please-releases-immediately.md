# ADR 032: Bypass Release Please on merged release commits

**Status:** Implemented
**Date:** 2026-05-28

## Context

The repository uses Release Please to manage version bumps, changelog updates,
and release PRs. The release workflow also builds four archives, generates
checksums, and updates the Homebrew tap after a release PR is merged.

Two incompatible behaviors surfaced on `2026-05-28`:

1. With `release-please-config.json` set to `"draft": true`, the push for
   merged release commit `c1ec1c3` (`chore(main): release 1.17.0 (#50)`)
   created draft release `v1.17.0`, then failed to recognize that release as
   the latest one inside the same run, reconsidered historical commits, and
   opened duplicate release PR `#51`.
2. Changing Release Please to publish immediately avoided the duplicate PR, but
   the release became immutable before the build jobs uploaded assets. The next
   release run for merged commit `518fce3` (`chore(main): release 1.18.0 (#51)`)
   failed every `gh release upload` step with `HTTP 422: Cannot upload assets
   to an immutable release`.

The repository therefore needs Release Please to keep managing release PRs,
while a separate workflow path owns the actual GitHub release object so assets
can be uploaded before publication.

## Decision

Keep `release-please-config.json` on `"draft": true`, but stop running Release
Please on merged release commits.

Instead, `.github/workflows/release.yml` now:

1. detects whether `HEAD` is a merged release commit like
   `chore(main): release 1.18.0 (#51)`,
2. skips the reusable Release Please workflow for those commits,
3. extracts the just-merged release notes from `CHANGELOG.md`,
4. creates or reuses a draft GitHub release for the manifest version,
5. uploads archives and checksums to that draft release, and
6. publishes the release only after the assets are in place.

On ordinary commits to `main`, the workflow still runs Release Please to create
or update the pending release PR.

## Consequences

- Merged release commits no longer trigger the duplicate-PR path in Release
  Please because the workflow does not invoke it for those commits.
- Release assets remain uploadable because the workflow owns a draft release
  until archives and checksums are attached.
- Reruns stay idempotent: the workflow reuses an existing draft release for the
  tag and skips uploads for assets that are already present.

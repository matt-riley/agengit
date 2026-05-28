# ADR 032: Publish Release Please releases immediately

**Status:** Implemented
**Date:** 2026-05-28

## Context

`release-please-config.json` configured the root package with `"draft": true`.
That let Release Please create a draft GitHub release as soon as a release PR
merged, while the rest of `.github/workflows/release.yml` uploaded archives,
checksums, and the Homebrew formula before publishing the release.

In practice that draft setting caused Release Please to mis-detect the just-cut
release inside the same workflow run. On the push for merged release commit
`c1ec1c3` (`chore(main): release 1.17.0 (#50)`), the Release Please job:

1. created release `v1.17.0`,
2. removed `autorelease: pending` and added `autorelease: tagged` to PR `#50`,
3. then started its PR-building phase,
4. logged `Expected 1 releases, only found 0`,
5. concluded `No latest release found for path: .`,
6. reconsidered the full historical commit set, and
7. opened duplicate release PR `#51`.

This matches the upstream duplicate-PR behavior reported for draft releases in
googleapis/release-please-action issue `#962`.

## Decision

Set `"draft": false` for the root Release Please package.

The repository will now let Release Please create a published GitHub release
immediately when a release PR merges. The follow-on workflow jobs still upload
archives, checksums, and update the Homebrew tap against that same release.

## Consequences

- Merging a release PR no longer causes the same workflow run to open the next
  release PR from the same historical commits.
- GitHub may briefly show a newly published release before all archives and
  checksums finish uploading.
- The later `Publish release` workflow step becomes effectively idempotent; it
  can remain in place as a harmless no-op until the workflow is simplified in a
  future change.

# ADR 013: CI hardening — sanitizers, fuzz, and matrix breadth

**Status:** Implemented
**Date:** 2026-05-25

## Context

`.github/workflows/ci.yml` currently runs:

- `zig build check-fmt`
- `zig build test`
- A small matrix on Linux + macOS, ReleaseSafe + Debug.

What is missing relative to a tool that writes user-owned config and a
durable on-disk store:

1. No sanitizer build. Zig's `-fsanitize-c` and `-fsanitize=undefined` are
   trivial to add and catch real bugs.
2. No fuzz testing of hook payload parsers. Hook stdin is the primary
   untrusted-input boundary.
3. No round-trip tests of the on-disk store under randomised step
   sequences.
4. No musl or static-link variant, even though releases ship static
   binaries.
5. CI does not run `agit doctor` against a freshly-recorded store, so a
   regression that breaks doctor invariants ships unnoticed.

## Decision

Add four new CI jobs alongside the existing build+test matrix:

1. **`sanitizers`** — Linux x86_64, Debug build with `-fsanitize=undefined`
   (via Zig's `-fsanitize-c`; address sanitizer is not exposed by Zig 0.16's
   standard build API), runs full unit + integration tests.
2. **`fuzz`** — runs three hook-payload mutational harnesses (Claude, Codex,
   Gemini) for a bounded wall-clock budget. PRs cap the total budget at
   60 seconds; the nightly schedule runs 30 minutes total so each harness gets
   roughly 10 minutes. Crashing inputs are written to a `crash-corpus`
   directory so CI can upload them as artifacts.
3. **`store-roundtrip`** — generates N random step sequences, replays them
   through the recorder, then runs `agit reindex` and asserts the output
   matches the index produced during recording. Lives under
   `tests/property/`.
4. **`smoke-doctor`** — runs `agit init`, fires a synthetic hook payload,
   then runs `agit doctor` and `agit status`, asserting a healthy store and the
   expected captured step count.

The release workflow already ships the four advertised archive targets, so the
CI hardening work leaves `.github/workflows/release.yml` untouched.

## Plan

1. Add `.github/workflows/ci.yml` jobs for `sanitizers`, `fuzz`,
   `store-roundtrip`, and `smoke-doctor`, plus a nightly fuzz schedule.
2. Add `tests/fuzz/hooks.zig` and `tests/property/all.zig`, with build targets
   exposed as `zig build fuzz-hooks` and `zig build test-property`.
3. Add `scripts/smoke-doctor.sh` so the doctor smoke path can be exercised
   locally and in CI against temp HOME/repo state.
4. Keep Zig pinned to `0.16.0` in CI matching `build.zig.zon`.

## Testing

- The new jobs are themselves the tests. Validate by:
  - running `zig build test-property`;
  - running `zig build fuzz-hooks -- --time=60s`;
  - running `./scripts/smoke-doctor.sh`;
  - running `zig build test test-e2e -Doptimize=Debug -fsanitize-c`.

## Risks and tradeoffs

- CI minutes increase. The fuzz job dominates; cap PR runs at 60 seconds
  total and push longer runs to the nightly schedule.
- Sanitizer builds are slower; restrict to one Linux job rather than the
  full matrix.
- The fuzz runner is mutational rather than coverage-guided, so it relies on
  good seed payloads and crash-corpus retention to stay effective.

## Consequences

- The store, recorder, and hook parsers gain real adversarial coverage.
- Memory safety regressions surface in CI instead of in a user's terminal.
- The four advertised release archives continue to be built and uploaded by the
  existing release workflow, while CI now checks the recorder and doctor paths
  more directly.
- A `crash-corpus` artifact grows organically and feeds back into
  property tests over time.

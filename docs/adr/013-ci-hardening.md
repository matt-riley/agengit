# ADR 013: CI hardening — sanitizers, fuzz, and matrix breadth

**Status:** Proposed
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
   and `-fsanitize=address` (where Zig supports), runs full unit + integration
   tests.
2. **`fuzz`** — runs three fuzz harnesses (one per agent's hook payload
   parser) for a bounded time (default 60 seconds each on PR, 10 minutes
   nightly). Uses Zig's built-in fuzz support or `afl++` via a thin
   harness, whichever lands first.
3. **`store-roundtrip`** — generates N random step sequences, replays them
   through the recorder, then runs `agit reindex` and asserts the output
   matches the index produced during recording. Lives under
   `tests/property/`.
4. **`smoke-doctor`** — runs `agit init`, fires a synthetic hook payload,
   then runs `agit doctor` and asserts it exits 0 and reports the expected
   step count.

Release matrix gains musl and aarch64 cross builds.

## Plan

1. Add `.github/workflows/ci.yml` jobs for the four above. Reuse the
   existing setup-zig action.
2. Add `bench/` and `tests/property/` directories with the fuzz/roundtrip
   harnesses.
3. Pin the Zig version to `0.16.0` in CI matching `build.zig.zon`. Add a
   `setup-zig` cache key to avoid downloading each run.
4. Update `release.yml` to add `aarch64-linux-musl` and an SLSA-style
   provenance step (out of scope to detail here; tracked separately).
5. Add a nightly schedule that runs fuzz for 10 minutes and uploads any
   crashing inputs to a `crash-corpus` artifact.

## Testing

- The new jobs are themselves the tests. Validate by:
  - intentionally introducing a use-after-free in a branch and confirming
    the sanitizer job fails;
  - committing a malformed corpus input and confirming the fuzz harness
    reports it.

## Risks and tradeoffs

- CI minutes increase. The fuzz job dominates; cap PR runs at 60 seconds
  total and push longer runs to the nightly schedule.
- Sanitizer builds are slower; restrict to one Linux job rather than the
  full matrix.
- Cross-compiled musl needs a working zig cross toolchain; Zig 0.16
  handles this natively.

## Consequences

- The store, recorder, and hook parsers gain real adversarial coverage.
- Memory safety regressions surface in CI instead of in a user's terminal.
- Release artifacts widen to cover the platforms our README already
  advertises (`aarch64-linux`, `x86_64-linux`, `aarch64-macos`,
  `x86_64-macos`) with consistent hardening.
- A `crash-corpus` artifact grows organically and feeds back into
  property tests over time.

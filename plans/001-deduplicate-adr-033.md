# Plan 001: Deduplicate ADR number 033

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report — do not improvise. When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat bae6a6c..HEAD -- docs/adr/`
> If any ADR file changed since this plan was written, compare the "Current state" excerpts against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `bae6a6c`, 2026-06-20

## Why this matters

The `docs/adr/` directory currently contains two files named `033-...`. Any link, script, or human reference to "ADR 033" is ambiguous. Renaming the later ADR to the next free number removes the ambiguity and keeps the numbering monotonic.

## Current state

- `docs/adr/033-evidence-based-session-evaluation.md` — original ADR 033.
- `docs/adr/033-git-commit-session-correlation.md` — second ADR that also claims 033. Its header is:

```markdown
# ADR 033: Git commit and session correlation
```

The highest existing ADR number in the directory is `040-copilot-extension-install.md`, so the next free number is `041`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Verify no duplicate 033 | `ls docs/adr/ | grep '^033' | wc -l` | `1` |
| Verify renamed header | `head -1 docs/adr/041-git-commit-session-correlation.md` | `# ADR 041: Git commit and session correlation` |
| Checks | `zig build check-docs` | exit 0 |

## Scope

**In scope**:
- `docs/adr/033-git-commit-session-correlation.md` → rename and update header.

**Out of scope**:
- `docs/adr/033-evidence-based-session-evaluation.md` (leave as ADR 033).
- Any code or CI workflow changes.

## Steps

### Step 1: Rename the file

Rename `docs/adr/033-git-commit-session-correlation.md` to `docs/adr/041-git-commit-session-correlation.md`.

**Verify**: `ls docs/adr/033-git-commit-session-correlation.md` should fail with `No such file or directory`.

### Step 2: Update the header

Open `docs/adr/041-git-commit-session-correlation.md` and change the first line from:

```markdown
# ADR 033: Git commit and session correlation
```

to:

```markdown
# ADR 041: Git commit and session correlation
```

**Verify**: `head -1 docs/adr/041-git-commit-session-correlation.md` prints `# ADR 041: Git commit and session correlation`.

### Step 3: Check for references

Search the repo for any text referencing the old path or old ADR number.

```sh
rg "033-git-commit-session-correlation|ADR 033.*Git commit"
```

**Verify**: no matches.

## Test plan

No code changes, so no new unit tests. The `check-docs` smoke test covers link integrity.

## Done criteria

- [ ] Only one file in `docs/adr/` starts with `033`.
- [ ] `docs/adr/041-git-commit-session-correlation.md` exists.
- [ ] The renamed file’s H1 reads `# ADR 041: Git commit and session correlation`.
- [ ] `zig build check-docs` exits 0.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report if:
- Another ADR now uses number `041` (check `ls docs/adr/`).
- `zig build check-docs` fails for a reason unrelated to this rename.

## Maintenance notes

Future ADRs should pick the next unused number after scanning the directory.

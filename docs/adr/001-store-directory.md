# ADR 001: Use `.agit/` as the store directory

**Status:** Accepted
**Editorial note:** Reworded on 2026-05-25 for clarity; the decision is unchanged.

## Context

`agit` needs one predictable place to keep its local session history: objects, refs, the SQLite index, hook logs, and temporary hook staging files.

The reference project, `re_gent`, uses `.regent/`. Reusing that path too early would look convenient, but it could also mix two tools' data before byte-level compatibility exists. That is the sort of shortcut that starts as "probably fine" and ends as a tiny haunted basement.

## Decision

Use `.agit/` as the exclusive v1 store directory.

```text
.agit/
|-- objects/
|-- refs/
|   `-- sessions/
|-- log/
|-- tmp/
`-- index.db
```

Project-specific ignore rules live in `.agitignore` at the repository root.

## Consequences

- Users will not accidentally mix `agit` and `re_gent` stores.
- `.agit/` must stay out of git; it is local session history.
- Future `.regent/` import or migration support must be explicit and documented.
- Examples, tests, and user-facing docs should use `.agit/` consistently.

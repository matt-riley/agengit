# Contributing

## Local validation

Use Zig `0.16.0`.

Run this before pushing:

```sh
zig build check
```

That covers formatting, markdown link validation, release metadata validation,
and unit tests.

When you change CLI behavior, hook flows, recorder behavior, or repository
fixtures, also run:

```sh
zig build test-e2e
```

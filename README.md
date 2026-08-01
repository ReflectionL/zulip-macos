# Zulip Mac

Zulip Mac is an independent, native macOS client for
[Zulip](https://zulip.com/). It explores a quiet, keyboard-first interface
inspired by modern developer tools while preserving Zulip's channel and topic
model.

> This project is experimental and is not an official Zulip client.

## Status

The project is in its foundation phase. Progress and acceptance evidence live
in [`TRACKER.md`](TRACKER.md); the full roadmap lives in
[`PLAN.md`](PLAN.md).

## Architecture

- **Swift 6 / SwiftUI / AppKit** — macOS presentation and platform integration.
- **Rust** — Zulip API, real-time event synchronization, domain state, SQLite
  caching, content normalization, and authenticated media caching.
- **UniFFI** — a narrow command/event/snapshot bridge between Swift and Rust.

The initial target is macOS 26+ on Apple Silicon.

## Repository Layout

```text
app/       Swift package and macOS application
core/      Rust workspace and FFI crate
docs/      Architecture, security, and release documentation
fixtures/  Deterministic preview and test data
scripts/   Reproducible build and verification commands
```

## Development

Read [`AGENTS.md`](AGENTS.md) before making changes. Every completed development
step must update both `PLAN.md` and `TRACKER.md`.

The documented command surface is:

```bash
./scripts/bootstrap.sh
./scripts/build-core.sh
./scripts/generate-bindings.sh
./scripts/build-app.sh
./scripts/test.sh
./scripts/check.sh
./scripts/package-app.sh release
./scripts/package-dmg.sh release v0.1.0-alpha.1
```

Foundation steps add these commands progressively. The currently available
documentation check is:

```bash
./scripts/check-docs.sh
```

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).

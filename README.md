# Zulip Mac

Zulip Mac is an independent, native macOS client for
[Zulip](https://zulip.com/): a quiet, keyboard-first interface that keeps
Zulip's channel and topic model.

> Experimental and not an official Zulip client.

## Status

Public pre-release, used daily by its author. It targets macOS 26 on Apple
Silicon, supports one account at a time, and has been tested live against Zulip
Cloud. Standard self-hosted servers are covered by protocol mocks but have not
passed a real smoke test yet.

Progress is tracked in [`TRACKER.md`](TRACKER.md) and the roadmap in
[`PLAN.md`](PLAN.md).

## Features

- **Account and sync** — password or API-key login (the key lives only in
  Keychain); live event sync that recovers from sleep, drops and expired
  queues; cached offline reading and per-conversation drafts.
- **Reading** — **Mentions** and **Starred** (the app opens on Mentions),
  channels with topics, and direct messages with presence, status and unread
  counts. Element-style message blocks, older-history paging, server-side
  search, a quick switcher, and read receipts (Zulip 6.0+).
- **Content** — Markdown, links and link cards, mentions, emoji, quotes, lists,
  code, images, tables and LaTeX formulas, all rendered natively. Untrusted
  HTML is sanitized in Rust and never shown in a web view.
- **Writing** — send, edit, delete, react, star, quote, forward and mark
  read/unread, with pending, rollback and retry states; `@` suggestions; file
  upload (button or drag and drop, up to 25 MiB); topic and channel
  management.
- **Notifications** — local notifications for direct messages, mentions and
  channels or followed topics you enabled, with per-topic Followed / Default /
  Muted levels synced to Zulip, an unread Dock badge, and catch-up after
  reconnecting. Messages are never marked read while the app is in the
  background or the screen is locked.
- **Appearance** — light and dark mode, adjustable text size, and Normal or
  Compact message density.
- **Updates** — checks GitHub releases at launch and from **Check for
  Updates…**; installing verifies the SHA-256 and code signature.

| Shortcut | Action |
| --- | --- |
| ⌘K | Quick switcher |
| ⌘F | Search messages |
| ⌘1 / ⌘2 | Mentions / Starred |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next conversation |
| ⇧⌘L | Focus the composer |
| ⌃⌘S | Show or hide the sidebar |
| ⌘+ / ⌘− / ⌘0 | Larger / smaller / default text |

## Install

Download the latest `Zulip-Mac-*-arm64.dmg` from the
[Releases page](https://github.com/ReflectionL/zulip-macos/releases) (macOS 26+,
Apple Silicon) and drag **Zulip Mac** to **Applications**.

Builds are ad-hoc signed and **not notarized**: on first launch, right-click the
app and choose **Open**, and check the download against the attached SHA-256
file. Do not disable Gatekeeper globally.

## Known limitations

- One active account; no browser SSO, self-signed certificates, Intel Macs, App
  Store distribution or administration.
- Offline use is read-only; failed writes are retried by hand, not replayed.
- Custom (image) emoji appear as `:name:` and cannot be picked yet.
- LaTeX supports common syntax only (no custom macros); inline formulas show as
  one line of text, and unknown commands are shown as written.
- Tables hold inline content only and are cut to 200 rows and 24 columns.
- A moved message shows "(edited)", like an edited one.
- The media cache has no size limit yet, and read receipts rely on polling
  (`REL-001`).
- Releases are not notarized and the self-hosted smoke test is pending
  (`REL-005`).

## Development

Swift 6 / SwiftUI owns the macOS UI and platform integration; a Rust workspace
owns the Zulip API, sync, SQLite cache, content normalization and media cache;
UniFFI bridges them with commands, events and snapshots.

```text
app/       Swift package and macOS application
core/      Rust workspace (zulip-core, zulip-ffi) and bindings tool
docs/      Release notes and other documentation
fixtures/  Deterministic preview and test data
scripts/   Build and verification commands
```

Read [`AGENTS.md`](AGENTS.md) first; every step updates both `PLAN.md` and
`TRACKER.md`. Building needs macOS 26, Xcode with Swift 6, the Rust toolchain
pinned in `rust-toolchain.toml`, and `ripgrep`.

```bash
./scripts/bootstrap.sh      # verify the toolchain
./scripts/check.sh          # docs check, rustfmt, clippy, tests
./scripts/build-app.sh      # build the app
./scripts/package-dmg.sh release v0.1.0-beta.1
```

Rust-only changes can be checked anywhere with `cargo fmt`, `cargo clippy` and
`cargo test` in `core/`. The Swift app compiles only on macOS, where CI
(`.github/workflows/ci.yml`) runs `./scripts/check.sh` on every pull request.

Releases are built by the **Release** workflow on a macOS 26 runner: run it with
a version tag such as `v0.1.0-beta.1` (a tag with `-` is a prerelease). It
publishes the DMG and its SHA-256 file, which the in-app updater reads.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).

# Zulip Mac

Zulip Mac is an independent, native macOS client for
[Zulip](https://zulip.com/). It explores a quiet, keyboard-first interface
inspired by modern developer tools while preserving Zulip's channel and topic
model.

> This project is experimental and is not an official Zulip client.

## Status

Zulip Mac is in public **alpha** and is used daily by its author. It targets
macOS 26 on Apple Silicon only, supports one account at a time, and has been
exercised live against Zulip Cloud. Standard self-hosted servers are covered by
protocol mocks but have not yet passed a real self-hosted smoke test.

Progress and acceptance evidence live in [`TRACKER.md`](TRACKER.md); the full
roadmap lives in [`PLAN.md`](PLAN.md).

## Features

**Account and sync**

- Password or API-key login to Zulip Cloud and standard HTTPS servers. The API
  key is stored only in macOS Keychain and the saved account reconnects on
  launch.
- Live event sync with backoff, a "Reconnecting…" indicator, immediate retry
  when the Mac wakes, and recovery from expired event queues.
- Offline reading: the last sidebar and every opened conversation are cached in
  SQLite; drafts are saved per conversation. Writes while offline require an
  explicit retry after reconnecting.

**Reading**

- Sidebar with **Mentions** and **Starred** (opens on Mentions), channels with
  expandable topics, and direct messages ordered by recent activity with
  online/idle/offline presence. The organization icon and user avatars are shown.
- Unread counts on channels, topics, direct messages and Mentions (muted
  channels show none). Opening a collection, or a conversation while the app is
  in the background, does not mark messages read.
- Conversations load 50 messages at a time with older-history paging and a
  header showing the sender's last activity in one-to-one chats. The layout
  follows Element: consecutive messages from one person share a block that
  opens with the avatar and the sender's name (colored per person) beside it;
  pointing at a message highlights it and shows its time in small gray text on
  the left (the tooltip has the full date); a centered date line separates
  days.
- Server-side message search and a quick switcher.
- Native rendering of Zulip content: Markdown, links, mentions, emoji, quotes,
  lists, code and images. Images keep their real aspect ratio (height capped),
  pictures from other sites go through the server's preview, an uploaded
  picture that was only linked (no server preview) is still shown, a
  previewed picture's file link is hidden, and clicking opens the default
  viewer. Untrusted HTML is parsed in Rust and never shown in a web
  view.
- Read receipts: small overlapping avatars under your newest sent message show
  who has read it (needs Zulip 6.0 and read receipts enabled by the
  organization).

**Writing and actions**

- Send, edit, delete, react, star, mark read/unread, quote and reply, and
  forward, each with visible pending, rollback and retry states. Edited
  messages end with a small gray "(edited)" on the same line as the text.
- Emoji reactions: a quick row of ten recommended emoji plus a searchable list
  of all standard emoji (type a word or paste an emoji). Existing reactions
  show their counts, highlight your own, and toggle on click. Custom (realm)
  emoji appear as `:name:` text and cannot be picked yet.
- `@` mention suggestions in the composer, Shift/Option+Return for a line
  break, file upload up to 25 MiB (attach button or drag files from Finder
  onto the conversation) with authenticated media caching.
- Topic workflows: start a topic, rename a topic, move a message. Channels can
  be created and renamed.

**Notifications**

- Local notifications follow your Zulip settings: direct messages and
  @-mentions, every message in channels you turned desktop notifications on
  for (or that follow your account default), and every message in **followed**
  topics. Muted channels and topics stay quiet, except that an @-mention of you
  still notifies (an @all does not). Turn a channel's notifications on or off
  from its context menu in the sidebar, or use "Notify for All Channel
  Messages" in the gear menu.
- Topics have Zulip's three levels: right-click a topic for **Follow Topic**
  (a small bell appears and every message notifies), **Default** (the topic
  behaves like its channel) or **Mute Topic** (dimmed, no notifications or
  unread counts); inside a muted channel there is also **Unmute Topic**. All
  of this is saved to Zulip (per-topic levels need Zulip 7.0), so the web app
  agrees; this includes each channel's **general chat** topic. Clicking a
  notification opens the message. The Dock badge shows unread direct messages
  plus unread mentions in unmuted channels and topics.
- Messages that arrive while the connection is being re-established (for
  example after the Mac sleeps) still notify once it is back. The app keeps
  macOS from napping it while signed in so notifications are not delayed; if
  the system refuses a notification, the Dock icon bounces instead.
- The app asks macOS for permission to notify as soon as it opens, so a new
  install or an update shows the Allow prompt right away. Settings ›
  Notifications shows whether notifications are allowed and can ask again,
  open the app's page in System Settings, or send a test notification.

**Keyboard and appearance**

| Shortcut | Action |
| --- | --- |
| ⌘K | Quick switcher / command palette |
| ⌘F | Search messages |
| ⌘1, ⌘2 | Go to Mentions, Starred |
| ⌥⌘↑ / ⌥⌘↓ | Previous / next conversation |
| ⇧⌘L | Focus the message composer |
| ⌃⌘S | Show or hide the sidebar |
| ⌘+ / ⌘− / ⌘0 | Larger / smaller / default text size |

Light and dark appearance follow the system accent color and materials.

**Updates**

- The app checks GitHub releases at launch (at most every six hours) and from
  **Check for Updates…**. *Install and Restart* downloads the DMG, verifies its
  SHA-256 and code signature, swaps the app and relaunches it.

## Installation

Download the latest `Zulip-Mac-*-arm64.dmg` from the
[Releases page](https://github.com/ReflectionL/zulip-macos/releases) (macOS 26
or newer, Apple Silicon). Drag **Zulip Mac** to the **Applications** alias.

Builds are ad-hoc signed and **not notarized**. On first launch, right-click
the app and choose **Open**. Verify the download against the attached SHA-256
file. Do not disable Gatekeeper globally.

## Known limitations

- One active account; no browser SSO, self-signed certificates, Intel Macs,
  App Store distribution or administration.
- Offline use is read-only; failed writes are retried by hand, not replayed.
- A message that was moved to another topic or channel shows "(edited)", like
  an edited one.
- Custom (image) emoji appear as `:name:`; complex formulas and tables are not
  rendered.
- The media cache has no aggregate size limit yet (`REL-001`).
- Read receipts rely on polling because Zulip sends no event when a message is
  read.
- Releases are not notarized and the self-hosted live smoke is still pending
  (`REL-005`).

## Architecture

- **Swift 6 / SwiftUI / AppKit** — macOS presentation and platform integration.
- **Rust** — Zulip API, real-time event synchronization, domain state, SQLite
  caching, content normalization, and authenticated media caching.
- **UniFFI** — a narrow command/event/snapshot bridge between Swift and Rust.

## Repository Layout

```text
app/       Swift package and macOS application
core/      Rust workspace (zulip-core, zulip-ffi) and bindings tool
docs/      Release notes and other documentation
fixtures/  Deterministic preview and test data
scripts/   Reproducible build and verification commands
```

## Development

Read [`AGENTS.md`](AGENTS.md) before making changes. Every completed development
step must update both `PLAN.md` and `TRACKER.md`.

Building requires a Mac with macOS 26, Xcode with the Swift 6 toolchain, and
the Rust toolchain pinned in `rust-toolchain.toml` (installed through `rustup`).
`ripgrep` is needed by the documentation check.

```bash
./scripts/bootstrap.sh       # verify the toolchain
./scripts/build-core.sh      # build the Rust core
./scripts/generate-bindings.sh
./scripts/build-app.sh
./scripts/test.sh            # Rust and Swift tests
./scripts/check.sh           # docs check, rustfmt, clippy, tests
./scripts/package-app.sh release
./scripts/package-dmg.sh release v0.1.0-beta.1
```

Rust-only changes can be checked on any platform with `cargo fmt`,
`cargo clippy` and `cargo test` in `core/`; the Swift app compiles only on
macOS, where CI (`.github/workflows/ci.yml`) runs `./scripts/check.sh` on every
pull request.

## Releases

Releases are built by the **Release** GitHub Actions workflow on a macOS 26
runner. Run it with *Run workflow* (`workflow_dispatch`) and enter the version
tag, for example `v0.1.0-beta.1`; pushing a matching `v*` tag also starts it.
The workflow runs the full checks, packages the arm64 DMG, and publishes a
GitHub release (a tag containing `-` is marked as a prerelease) with the DMG and
its SHA-256 file. The in-app updater reads these releases.

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE).

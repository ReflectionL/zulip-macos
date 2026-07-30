# Zulip Mac Development Tracker

Last updated: 2026-07-30

## Current State

- Milestone: CORE — live Zulip vertical slice
- Current step: `CORE-006`
- Next step: `MVP-001`
- Overall status: in progress

## Step Status

| ID | Status | Started | Completed | Implementation and evidence | Blocker | Commit/PR |
| --- | --- | --- | --- | --- | --- | --- |
| DOC-001 | done | 2026-07-30 | 2026-07-30 | Added and cross-linked `AGENTS.md`, `PLAN.md`, and `TRACKER.md`; verified required workflow text and local file presence with `rg` and `find`. | — | — |
| DOC-002 | done | 2026-07-30 | 2026-07-30 | Initialized `main`; added directory skeleton, `.gitignore`, Apache-2.0 license, README, and `scripts/check-docs.sh`. Verification: documentation check passed and `git status --short --branch` reported the expected new files. | — | — |
| FND-001 | done | 2026-07-30 | 2026-07-30 | Added a macOS 26 SwiftUI executable package and a two-crate Rust workspace. `cargo test --workspace`: 2 passed. `swift test --disable-sandbox --package-path app` with workspace-local module cache: 1 passed. | — | — |
| FND-002 | done | 2026-07-30 | 2026-07-30 | Added bootstrap/build/test/check scripts and macOS 26 arm64 CI. `./scripts/check.sh`, both release builds, `git diff --check`, and workflow YAML parsing passed. | — | — |
| FND-003 | done | 2026-07-30 | 2026-07-30 | Added UniFFI 0.32.0, generated Swift bindings and a static XCFramework, plus `LiveCoreClient`. Rust and Swift round-trip tests pass; the debug application launched successfully. | — | — |
| UI-001 | done | 2026-07-30 | 2026-07-30 | Added adaptive semantic color, typography, spacing, radius, stroke, focus, and selection tokens plus light/dark previews. `./scripts/test.sh`: 5 Swift tests and 2 Rust tests passed. | — | — |
| UI-002 | done | 2026-07-30 | 2026-07-30 | Added a native two-column `NavigationSplitView`, custom sidebar toggle, standard/compact previews, and app bundling script. Computer Use verified 272 pt default, 240 pt resize, and complete sidebar collapse in the running app. | — | — |
| UI-003 | done | 2026-07-30 | 2026-07-30 | Added immutable sidebar bridge models, deterministic fixtures, custom rows, unread badges, hover/selection/muted/presence states, and independent section collapse. 9 Swift tests passed; Computer Use verified collapse and DM selection in the running app. | — | — |
| UI-004 | done | 2026-07-30 | 2026-07-30 | Added stable channel/topic/DM destinations, deterministic search ranking, topic drill-down, and a keyboard-accessible Quick Switcher. `./scripts/test.sh`: 14 Swift and 2 Rust tests passed. Computer Use verified ⌘K, `rust` filtering, Return routing to `#engineering / Rust core`, and a single native sidebar control. | — | — |
| UI-005 | done | 2026-07-30 | 2026-07-30 | Added `ConversationPage`, `MessageViewData`, and `ContentBlock` bridge values; a 1,000-message `LazyVStack`; path header; hover actions; bottom-follow behavior; jump-to-latest control; and fixed multiline composer. 16 Swift tests passed and the 1,000-message fixture constructs in under 2 seconds. Computer Use verified lazy visible rows, send/clear, and scroll recovery. | — | — |
| UI-006 | done | 2026-07-30 | 2026-07-30 | Added typed inline/block fixtures and native SwiftUI renderers for text, links, mentions, emoji, quotes, ordered/unordered lists, code, images, and unsupported-content fallback. 18 Swift and 2 Rust tests passed; light/dark `ImageRenderer` snapshots succeeded; source scan found no WebKit. Computer Use verified each block and accessible link/image/code semantics in the timeline. | — | — |
| UI-007 | done | 2026-07-30 | 2026-07-30 | Added deterministic loading/empty/error/offline fixtures, retry/reconnect paths, adaptive appearance snapshots, ⇧⌘L composer focus, selectable native text, composer hints, and message-level VoiceOver React/Star actions. `./scripts/test.sh`: 20 Swift and 2 Rust tests passed; all state/appearance renders succeeded. Computer Use verified empty/error/offline semantics and keyboard focus before the Mac auto-locked. | — | — |
| CORE-001 | done | 2026-07-30 | 2026-07-30 | Added normalized `ServerBaseUrl`, HTTPS/loopback policy, native-root Reqwest discovery, safe redirect and 1 MiB streaming limits, backward-compatible `server_settings` parsing, and sanitized capability records. 8 Rust core tests cover mock success/error and transport downgrade cases; Clippy passes with `-D warnings`; the full suite passes. Build scripts now fix Rust/C objects to macOS 26.0. | — | — |
| CORE-002 | done | 2026-07-30 | 2026-07-30 | Added password-to-key exchange, direct API-key validation via `/users/me`, shared TLS policy, zeroizing/redacted Rust secrets, and an account-scoped macOS data-protection Keychain store with add/update/load/delete behavior. 12 Rust core tests, 24 Swift tests, strict Clippy, and the full `./scripts/check.sh` pass. | — | — |
| CORE-003 | done | 2026-07-30 | 2026-07-30 | Added bundled SQLite, transactional `user_version` migrations, WAL/foreign-key/busy-timeout configuration, and STRICT account-scoped tables for accounts, users, channels, topics, messages, unread state, drafts, and sync metadata. Tests verify reopen, isolation, foreign keys, rollback, and absence of credential columns. 17 Rust core tests, strict Clippy, and full checks pass. | — | — |
| CORE-004 | done | 2026-07-30 | 2026-07-30 | Added authenticated `/register` bootstrap and `/events` long-poll transport with bounded responses and server-advertised timeouts; normalized initial users/channels and live message, subscription, user, update, delete, unknown, and heartbeat events; added an ordered idempotent reducer that tolerates nonconsecutive IDs and emits one immutable snapshot per changed batch. `./scripts/check.sh`: 22 Rust core tests, 1 FFI test, 24 Swift tests, strict Clippy, builds, and documentation checks pass. | — | — |
| CORE-005 | done | 2026-07-30 | 2026-07-30 | Added bounded exponential backoff with deterministic jitter, retryable/fatal classification, typed `BAD_EVENT_QUEUE_ID`, `restart` event handling, and a recovery-aware `SyncSession` that preserves cached state during disconnects and atomically replaces it after full registration. Deterministic disconnect, expiry, restart, duplicate, and nonconsecutive-ID tests pass. `./scripts/check.sh`: 26 Rust core tests, 1 FFI test, 24 Swift tests, strict Clippy, builds, and docs pass. | — | — |
| CORE-006 | in_progress | 2026-07-30 | — | Added bounded conversation fetch, channel/direct text send with local echo IDs, and read-flag APIs; replaced the bridge ping payload with typed account/conversation/write commands and immutable events; added a Tokio actor for continuous sync, recovery, sends, reads, and snapshots; added password and direct API-key session commands, verified own-user identity, one-time redacted API-key handoff, Keychain save/reload, a native SwiftUI login sheet, fixture/live switching, live sidebar/navigation/timeline mapping, safe non-executing HTML fallback, pending local sends, automatic conversation refresh, and mark-read submission. Added `live_smoke` using the production Rust clients and a stdin-only wrapper. Fixed API authentication to preserve the API login email instead of replacing it with a possibly different profile email. Added a file-based macOS Keychain fallback when an ad-hoc development build lacks data-protection Keychain entitlements. The designated Zulip Cloud organization now passes password login, initial sync, Inbox fetch, self-DM send/receive, reopen, mark-read, Keychain save, disconnect, and password-free saved-key reconnect in the running app. `./scripts/check.sh`: 29 Rust core tests, 3 actor/FFI tests, 29 Swift tests, strict Clippy, formatting, builds, and docs pass. | One HTTPS self-hosted endpoint remains required. | initial commit; live-smoke follow-up |

Later milestones remain defined in `PLAN.md` and will be added here when they
become active; completed rows are never removed.

## Work Log

### 2026-07-30

- Began `DOC-001`.
- Confirmed the starting directory was empty.
- Confirmed the local toolchain: Xcode 26.6, Swift 6.3.3, Cargo 1.95.0, Rust
  1.95.0, and an arm64 host.
- Added initial project governance and architecture decisions to the three
  root documents.
- Completed `DOC-001`; verified all three files and their cross-document
  references.
- Began `DOC-002`.
- Completed `DOC-002`; `./scripts/check-docs.sh` passes and Git is initialized
  on `main`.
- Began `FND-001`.
- Completed `FND-001`; both language projects compile and their foundation
  tests pass on the arm64 host.
- Began `FND-002`.
- Completed `FND-002`; all local automation and release builds pass, and the
  CI workflow parses successfully.
- Began `FND-003`.
- Completed `FND-003`; verified generated bindings, static XCFramework linking,
  typed command/event correlation, and debug application startup.
- Began `UI-001`.
- Completed `UI-001`; token invariants and the full test suite pass.
- Began `UI-002`.
- Completed `UI-002`; the running app passed the manual resize/collapse matrix.
- Began `UI-003`.
- Completed `UI-003`; automated and running-app sidebar checks pass.
- Began `UI-004`.
- Completed `UI-004`; automated navigation coverage and running-app keyboard
  routing checks pass.
- Began `UI-005`.
- Completed `UI-005`; the large-fixture performance test and running-app
  timeline/composer checks pass.
- Began `UI-006`.
- Completed `UI-006`; semantic and rendered content snapshots plus the
  running-app native-content check pass.
- Began `UI-007`.
- Completed `UI-007`; automated appearance/state coverage and manual
  accessibility inspection pass. Milestone UI is complete.
- Began `CORE-001`.
- Completed `CORE-001`; mock discovery, URL/TLS policy, full suite, and strict
  lint checks pass.
- Began `CORE-002`.
- Completed `CORE-002`; mock authentication, Keychain behavior, redaction, and
  strict project checks pass.
- Began `CORE-003`.
- Completed `CORE-003`; migrations, account isolation, rollback, credential
  schema scanning, lint, and the full project suite pass.
- Began `CORE-004`.
- Completed `CORE-004`; fixture register/long-poll protocol, heartbeat and
  nonconsecutive event ordering, duplicate filtering, normalization, batched
  snapshots, strict lint, and the full project suite pass.
- Began `CORE-005`.
- Completed `CORE-005`; deterministic disconnect, exponential backoff,
  duplicate filtering, queue expiry, restart, and atomic resynchronization
  checks pass.
- Began `CORE-006`.
- Implemented the automated `CORE-006` transport and bridge slice: newest
  conversation fetch, channel/direct send, read flags, continuous actor-driven
  sync, typed UniFFI commands/events/snapshots, and Swift mapping. Full local
  checks pass; the step remains open for live UI wiring and the required Cloud
  plus self-hosted smoke tests.
- Completed the unattended `CORE-006` application wiring: password/API-key
  login, verified identity, redacted one-time API-key handoff to Keychain,
  saved-key reconnect, live sidebar/navigation/timeline state, safe raw-content
  fallback, topic/DM send, refresh, and automatic read flags.
- Added end-to-end mock coverage for password exchange through the Rust actor
  and Swift fake-core/Keychain coverage for login, persistence, conversation
  mapping, read flags, and sending. `./scripts/check.sh` passes with 29 Rust
  core tests, 3 FFI actor tests, and 28 Swift tests.
- Kept `CORE-006` open because the user is away from the Mac and the required
  Zulip Cloud plus HTTPS self-hosted credential smoke matrix cannot be run
  safely without credentials being entered locally.
- Saved the repository foundation through the unattended `CORE-006` wiring in
  the initial project commit, with implementation and control documents in the
  same change set.
- Added a redacted, stdin-only live smoke runner using the production
  authentication, sync, message, and read-state clients. It sends only a
  self-DM when authentication and initial registration have succeeded.
- Verified the public `https://chat.zulip.org/api/v1/server_settings` endpoint:
  Zulip Community, password authentication enabled, feature level 507.
- Attempted the authorized Cloud password login. The server returned
  `InvalidCredentials` during password-to-API-key exchange, before register,
  event polling, message sending, or any other account mutation. GUI testing
  was unavailable because the Mac remained locked.
- Corrected the default login server to the designated Zulip Cloud
  organization without storing an email or credential in source or fixtures.
- Reproduced the reported `event synchronization returned HTTP 401` after
  successful password authentication. A redacted request comparison showed
  that the profile email returned by `/users/me` differed from the API login
  email and caused every subsequent authenticated request to fail.
- Fixed authentication to preserve the API login identifier through sync and
  message clients. Regression fixtures now cover differing API/profile emails.
- Ran the production live smoke successfully against Zulip Cloud:
  authentication, initial sync (1 user, 3 channels), Inbox fetch, self-DM
  send/receive, reopen, and mark-read all passed.
- Re-ran `./scripts/check.sh`: 29 Rust core tests, 3 FFI actor tests, and 29
  Swift tests pass with strict formatting, lint, builds, and documentation
  checks.
- Verified the running app loads the real organization, channels, account, and
  Inbox after password login; the earlier HTTP 401 is resolved.
- Found that the ad-hoc development signature lacks the entitlements required
  by the data-protection Keychain. Added a macOS file-keychain fallback while
  retaining data-protection Keychain as the preferred path.
- Verified credential persistence end to end in the packaged app: password
  login saved the API key, disconnect returned to fixture mode, and
  `Use Saved API Key` reconnected to the real Inbox without a password.

## Known Issues and Technical Debt

- `xcodebuild -create-xcframework` emits harmless CoreSimulator warnings in the
  restricted local environment even though the macOS-only XCFramework succeeds.
- Signing and notarization require Developer ID credentials and remain
  conditional for the beta release.
- `CORE-006` still needs one HTTPS self-hosted smoke target to complete its
  two-server matrix; the Zulip Cloud target now passes.
- Live message bodies are displayed as inert text containing the server HTML
  during `CORE-006`; native sanitized `ContentBlock` parsing remains
  intentionally scheduled for `MVP-005`.

## Open Decisions

- Final public product name and icon are intentionally deferred until the UI
  prototype has a stable visual identity.

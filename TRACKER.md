# Zulip Mac Development Tracker

Last updated: 2026-08-01

## Current State

- Milestone: MVP — daily use
- Current step: `ALPHA-001` (`in_progress`)
- Next step: `MVP-006` (`ready`)
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
| CORE-006 | done | 2026-07-30 | 2026-07-31 | Added bounded conversation fetch, channel/direct text send with local echo IDs, and read-flag APIs; replaced the bridge ping payload with typed account/conversation/write commands and immutable events; added a Tokio actor for continuous sync, recovery, sends, reads, and snapshots; added password and direct API-key session commands, verified own-user identity, one-time redacted API-key handoff, Keychain save/reload, a native SwiftUI login sheet, fixture/live switching, live sidebar/navigation/timeline mapping, safe non-executing HTML fallback, pending local sends, automatic conversation refresh, and mark-read submission. Added `live_smoke` using the production Rust clients and a stdin-only wrapper. Fixed API authentication to preserve the API login email instead of replacing it with a possibly different profile email. Added a file-based macOS Keychain fallback when an ad-hoc development build lacks data-protection Keychain entitlements. The designated Zulip Cloud organization passes password login, initial sync, Inbox fetch, self-DM send/receive, reopen, mark-read, Keychain save, disconnect, and password-free saved-key reconnect in the running app. Deterministic mocks cover authentication, registration, long polling, queue expiry, restart recovery, messages, and read state. `./scripts/check.sh`: 29 Rust core tests, 3 actor/FFI tests, 29 Swift tests, strict Clippy, formatting, builds, and docs pass. | — | initial commit; `922c16c`; `ce1cc64` |
| MVP-001 | done | 2026-07-31 | 2026-07-31 | Added authenticated Inbox/Mentions/Starred/Unread narrows, bounded topic discovery, channel/topic/self-and-user DM navigation, stable account-scoped conversation keys, anchored older-message requests, duplicate-free ordered page merging, latest-page refresh, and loading UI. `./scripts/check.sh`: 31 Rust core tests, 4 FFI tests, 29 Swift tests, strict Clippy, formatting, builds, and docs pass. Real Cloud smoke opened every quick destination, a channel, a self-DM, and `#Zulip > 欢迎来到Zulip！`; loading history merged 6 older messages into an initial 10-message page without duplicates or reordering, preserved the viewport, and removed the load control at the oldest page. | — | — |
| MVP-002 | done | 2026-07-31 | 2026-07-31 | Added bounded server-side `search` narrows, immutable account-scoped result keys, anchored context loading, and correlated Rust actor events. Added a native search overlay with debouncing, loading/empty/error states, stale-response suppression, `⌘F`, result routing, viewport positioning, visible target highlighting, and live-refresh preservation. `./scripts/check.sh`: 32 Rust core tests, 6 FFI actor tests, 31 Swift tests, strict Clippy, formatting, builds, and docs pass. Real Cloud smoke searched a unique existing message, returned one result, opened its self-DM context, highlighted the target, and confirmed `⌘F` transfers focus from the composer to search. | — | — |
| MVP-002A | done | 2026-07-31 | 2026-08-01 | Implemented inline expandable channel topics, validated new-topic drafts, whole-topic rename via `change_all`, single-message moves via `change_one`, correlated success/failure state, and retry. `./scripts/check.sh` passes: 33 Rust core, 7 FFI actor, and 33 Swift tests; the mock write smoke verifies both PATCH propagation modes. Computer Use verified real-account topic discovery/routing, independent channel collapse/expand, rename and move dialogs, existing-topic choices, and a local new-topic draft with an empty timeline/composer; no live write was submitted. | — | — |
| MVP-003 | done | 2026-08-01 | 2026-08-01 | Added typed Rust edit/delete/reaction/read/star APIs, correlated UniFFI commands/events, server-derived flags/reactions, pending local sends, optimistic action state, failure rollback, explicit retry, native edit/delete/read actions, and an exact-target redacted live-action smoke. `./scripts/check.sh` passes with 34 Rust core, 8 FFI actor, and 34 Swift tests. The designated Cloud account passed disposable self-DM send, edit, reaction, star, unread/read, server reconciliation, and permanent deletion; prior disposable smoke data was also removed. | — | — |
| MVP-005 | done | 2026-08-01 | 2026-08-01 | Added bounded browser-grade Rust fragment parsing and native recursive blocks for paragraphs, safe links, user mentions, Unicode/custom emoji, quotes, lists, code, Zulip image previews, and readable unsupported fallbacks. Executable tags and unsafe URL schemes are stripped; malformed, oversized, deep, or high-node-count input is safely recovered or capped. Replaced raw HTML in UniFFI/Swift snapshots with typed content and native plain-text search previews. `./scripts/check.sh` passes: 39 Rust core, 9 FFI, and 34 Swift tests, plus strict Clippy, formatting, generated bindings, and app build. Computer Use connected through the saved Keychain credential and verified a real Notification Bot message renders `@花海` and `#Zulip MacOS` as native text/link with no raw HTML tags. | — | — |
| MVP-004 | done | 2026-08-01 | 2026-08-01 | Implemented 25 MiB multipart upload, server-normalized composer links, 32 MiB authenticated downloads, opaque account-partitioned atomic caching, original-image URL parsing, asynchronous FFI media tasks, a native file picker, visible retry state, composer insertion without auto-send, and off-main AppKit image decode. `./scripts/check.sh` passes with 45 Rust core, 10 FFI actor, and 37 Swift tests plus strict Clippy, binding regeneration, and app build. The designated Cloud account passed bounded PNG upload, disposable self-DM link send, server-rendered image parsing, authenticated download with exact byte validation, cache hit, and message/attachment-reference cleanup. | — | — |
| MVP-004A | done | 2026-08-01 | 2026-08-01 | Tightened the sidebar into the titlebar safe area, moved conversation identity/actions into the released native toolbar position, relocated connect/disconnect to an accessible bottom-left gear menu, preserved native sidebar collapse, and removed the composer separator. Generated an original flat icon master, transparent-corner PNG, multi-resolution ICNS, Info.plist identity, package copy, and icon decode test. `./scripts/check.sh` passes with 45 Rust core, 10 FFI actor, and 40 Swift tests including light/dark shell renders. The ad-hoc signed bundle passed `plutil`, `codesign --verify --deep --strict`, running-app menu/layout/collapse smoke, and Finder icon inspection. | — | — |
| MVP-004B | done | 2026-08-01 | 2026-08-01 | Restored the sidebar's titlebar safe area; replaced the macOS-generated glass sidebar toggle with one compact flat 13 pt control and a hover-only background; preserved mouse and `⌃⌘S` collapse/expand; restored the flat conversation breadcrumb; and forced search, topic actions, and details to the far-right group. `./scripts/check.sh` passes with 45 Rust core, 10 FFI actor, and 41 Swift tests, including a native-toolbar suppression regression test and light/dark shell renders. The ad-hoc packaged app passed real-account Inbox/topic visual smoke at 1348×768, 1081×721, and 824×612, with all three topic controls visible and no title/sidebar collision. | — | `3c4ecda` |
| ALPHA-001 | in_progress | 2026-08-01 | — | Preparing the first public Apple Silicon DMG and GitHub prerelease from the current verified UI build. This package is intentionally ad-hoc signed and unnotarized; `REL-005` remains the later beta-quality release gate. | — | — |

Later milestones remain defined in `PLAN.md` and will be added here when they
become active; completed rows are never removed.

## Work Log

### 2026-08-01

- Began `ALPHA-001` at the user's request. The release target is
  `v0.1.0-alpha.1`: a reproducibly built arm64 DMG plus checksum and GitHub
  prerelease notes that clearly disclose macOS 26+, ad-hoc signing, lack of
  notarization, and unfinished MVP work. This does not close `REL-005`.
- Closed `MVP-004B`. Fresh packaged-app screenshots, rather than accessibility
  output alone, verified the corrected standard, compact, and near-minimum live
  topic layouts. The sidebar control is now a single flat icon with hover-only
  feedback; the breadcrumb is plain typography; and search, topic actions, and
  details remain grouped at the far right. Mouse and `⌃⌘S` both collapse and
  restore the sidebar. Full verification passes with 45 Rust core, 10 FFI, and
  41 Swift tests; `MVP-006` is now ready.
- Began `MVP-004B` after the user's screenshot review rejected the prior visual
  result. Acceptance now explicitly requires fresh screenshots: traffic lights,
  sidebar control, and workspace identity must not collide; the oversized glass
  sidebar toggle must become a compact flat control; the breadcrumb must use its
  original flat style without a glass capsule; conversation actions must sit at
  the far right at both standard and compact widths.
- Closed `MVP-004A`. The conversation path and its search/topic/detail actions
  now live in the native window toolbar where the former session button sat;
  the sidebar extends safely into the titlebar region with a 28 pt top inset.
- Replaced the passive profile gear with an accessible menu. Fixture mode
  exposes `Connect to Zulip…` and live mode exposes destructive `Disconnect`;
  both retain the native `Settings…` link. The root-level connect/disconnect
  toolbar item was removed.
- Removed the separator above the fixed composer while retaining the composer's
  elevated rounded surface. The native sidebar toolbar control still collapses
  and restores the sidebar in the running packaged app.
- Generated the original minimalist threaded-conversation icon with the built-in
  image generation path, removed its chroma-key exterior into transparent
  corners, produced `AppIcon.png` and a multi-resolution `AppIcon.icns`, and
  bundled it through `CFBundleIconFile`. Finder displayed the packaged icon and
  the ad-hoc signed app passed strict code-signature verification.
- `./scripts/check.sh` passes with 45 Rust core, 10 FFI actor, and 40 Swift
  tests. Swift coverage includes light/dark full-shell rendering, session-menu
  action mapping, spacing constraints, and readable icon/plist identity.
- Running-app Computer Use verified the compact top spacing, toolbar title,
  gear menu (`Connect to Zulip…`, `Settings…`), absent composer divider, and
  sidebar collapse/restore. Marked `MVP-006` ready.
- Began `MVP-004A` at the user's request before offline/draft work. The active
  scope is limited to sidebar/titlebar spacing, session-control placement,
  composer chrome, and an original minimalist packaged app icon; `MVP-006`
  now depends on this visual polish step.
- Implemented the complete local `MVP-004` slice. Rust accepts only bounded
  regular-file uploads and same-origin `/user_uploads/` message routes, uses
  Zulip's short-lived authenticated download URL immediately without forwarding
  Basic auth, and writes cache files atomically under SHA-256 account/path
  partitions. Swift owns the file picker and security scope, inserts returned
  Markdown without sending, deduplicates media requests, and decodes only
  cache-owned file URLs off the main actor.
- Added adversarial and correlation coverage for multipart authentication,
  limits, unsafe/cross-origin paths, account isolation, cache hits, oversized
  cleanup, temporary-URL credential separation, actor events, Swift upload and
  media retry state, no-auto-send insertion, and native image decode. The local
  suites pass with 45 Rust core, 10 FFI, and 37 Swift tests; strict Clippy and
  the debug app build also pass.
- Added `live-media-smoke-keychain.sh`, which retrieves the existing API key
  only from macOS Keychain into local stdin, then uploads a 1×1 PNG, sends a
  disposable self-DM, parses the server-rendered image, verifies authenticated
  download/cache bytes, and deletes the message. The designated Cloud account
  passed every phase without printing or placing the API key in
  arguments/environment; the disposable message and its final attachment
  reference were deleted afterward.
- Closed `MVP-004` after the exact Cloud smoke and final `./scripts/check.sh`
  passed. Marked `MVP-006` ready as the next dependency-unblocked step.
- Began `MVP-004`. The active scope is bounded attachment upload, authenticated
  account-isolated media download/cache, safe local file references over FFI,
  and native Swift file selection/rendering without main-actor I/O.
- Closed `MVP-005`: live messages now cross UniFFI only as sanitized native
  content blocks; raw Zulip HTML no longer enters Swift snapshots or search
  previews.
- Added current Zulip-format coverage for span/image emoji, `codehilite`
  language metadata, nested uploaded-image previews and dimensions, plus
  malformed markup, unsafe schemes, executable tags, output limits, and every
  recursive FFI block kind.
- `./scripts/check.sh` passes with 39 Rust core tests, 9 FFI tests, and 34 Swift
  tests, strict Clippy, formatting, binding regeneration, and the debug app
  build.
- In the running app, the designated Cloud account reconnected using its saved
  Keychain API key. A real Notification Bot message displayed `@花海` and
  `#Zulip MacOS` natively with an accessible channel hyperlink and no `<p>`,
  `<a>`, or other raw HTML text. The smoke was read-only.
- Marked `MVP-004` ready; authenticated media upload/download/cache is the next
  step.
- Began `MVP-005` after the independently verified and pushed `MVP-003`
  changeset. The active scope is bounded Rust parsing, typed FFI blocks, native
  Swift rendering, adversarial fallback behavior, and a running-app rich-message
  smoke.
- Closed `MVP-003`: real sends now use view-model-owned pending local echoes;
  edits, deletes, `thumbs_up` reactions, stars, and read/unread writes cross the
  typed actor boundary with correlated success or sanitized failure. Optimistic
  state rolls back on failure and remains manually retryable; failed writes are
  never replayed automatically.
- Added server-backed message flags/reaction snapshots, native edit and delete
  surfaces, explicit permanent-delete confirmation, read-state menu actions,
  failure labels, and retry controls.
- `./scripts/check.sh` passes with 34 Rust core tests, 8 FFI actor tests, and 34
  Swift tests, plus strict Clippy, formatting, regenerated bindings, and the
  debug application build.
- The designated Cloud account passed a redacted, exact-target self-DM smoke:
  send, edit, add reaction, star, mark unread/read, refetch and reconcile server
  state, then delete the disposable message. The earlier GUI smoke message was
  found by its unique marker and deleted as cleanup. No credential was printed
  or passed as a command argument/environment value.
- Marked `MVP-005` ready.
- Reprioritized `MVP-005` ahead of files/media at the user's request. Updated
  dependencies so `MVP-003` closes first, then native content parsing, then
  `MVP-004`; `MVP-006` now waits for files/media as well.
- Began `MVP-003` with explicit real-write scope and correlated pending,
  rollback, and manual retry acceptance criteria.
- Completed the running-app `MVP-002A` smoke against the designated Cloud
  account: all three channels exposed inline topics; channel topics collapsed
  and expanded independently; selecting a topic loaded its stable route.
- Opened and cancelled the whole-topic rename sheet and the single-message
  move sheet. The move sheet listed the other existing topic in the channel.
  No Rename or Move action was submitted, so the live organization was not
  mutated.
- Started the local `Codex UI smoke draft` topic from `#Zulip`; it appeared in
  the sidebar and opened an empty timeline with its fixed composer. No message
  was entered or sent, so Zulip did not create a server topic.
- Closed `MVP-002A` after the prior full automated check (33 Rust core, 7 FFI
  actor, 33 Swift tests) and the running-app smoke both passed. Marked
  `MVP-003` ready.

### 2026-07-31

- Implemented the full `MVP-002A` protocol and UI slice: Rust message-topic
  updates, UniFFI commands/events, account-scoped topic snapshots, expandable
  channel trees, new-topic drafts, rename and move sheets, and retryable errors.
- `./scripts/check.sh` passes with 33 Rust core, 7 FFI actor, and 33 Swift
  tests. The mock Zulip actor observed `change_all` for whole-topic rename and
  `change_one` for a single-message move.
- Built, ad-hoc signed, and launched `dist/Zulip Mac.app`; the required
  running-app browse/create/dialog smoke remains pending because macOS locked
  before Computer Use could inspect the window. The step remains
  `in_progress`.
- Added and began `MVP-002A` at the user's request, preserving existing stable
  IDs while prioritizing inline topic browsing, topic creation, whole-topic
  rename, and single-message moves before general message actions.
- Began `MVP-002`; refined its acceptance criteria around server-side search,
  immutable account-scoped results, anchored conversation loading, visible
  target focus, stale-response handling, and off-main-actor transport.
- Implemented bounded Zulip `search` narrows, anchored message context, stable
  topic/direct result keys, correlated actor events, and Swift stale-response
  suppression.
- Added the native message-search overlay with debounce, loading/empty/error
  states, `⌘F`, keyboard result movement, result routing, target scrolling and
  highlight, and preservation of the target through live refresh.
- `./scripts/check.sh` passes with 32 Rust core, 6 FFI actor, and 31 Swift
  tests. Real Cloud search returned the unique expected result, opened its
  self-DM context, highlighted the target message, and passed composer-to-search
  focus transfer with `⌘F`.
- Closed `MVP-002` and marked `MVP-003` ready.
- Began `MVP-001`; refined its acceptance criteria around stable live
  destinations, duplicate-free historical pagination, immutable account-scoped
  pages, and off-main-actor network work.
- Implemented the Rust narrow/topic/pagination APIs, expanded the UniFFI actor
  contract, and wired live Swift navigation, quiet refresh, and ordered history
  merging.
- `./scripts/check.sh` passes with 31 Rust core, 4 FFI actor, and 29 Swift
  tests. The designated Cloud account passes Inbox, Mentions, Starred, Unread,
  channel, and self-DM browsing.
- Completed the running-app history smoke: the initial 10-message Inbox page
  loaded 6 older messages without duplicates or reordering, preserved the
  viewport, and removed the load control after reaching the oldest page.
- Confirmed the live quick switcher discovers topics and opens
  `#Zulip > 欢迎来到Zulip！` with the correct message narrow. Closed `MVP-001`
  and marked `MVP-002` ready.
- With user approval, revised the milestone boundary so successful Zulip Cloud
  live testing plus deterministic protocol mocks closes `CORE-006`.
- Moved the real standard HTTPS self-hosted smoke test to the mandatory
  `REL-005` GitHub Beta release gate; self-hosted product support remains in
  scope.
- Completed `CORE-006` using the existing Cloud live-smoke, running-app login,
  Keychain reconnect, mock recovery, and full-project verification evidence.
- Marked `MVP-001` as `ready`; no implementation step is currently active.

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
- `REL-005` must pass one real standard HTTPS self-hosted smoke target before
  a GitHub Beta can be published; the Zulip Cloud target already passes.
- The media cache has a strict 32 MiB per-file bound but no aggregate LRU quota
  yet; aggregate eviction belongs in `REL-001` performance/cache work.

## Open Decisions

- Final public product name and icon are intentionally deferred until the UI
  prototype has a stable visual identity.

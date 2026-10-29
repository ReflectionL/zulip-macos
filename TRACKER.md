# Zulip Mac Development Tracker

Last updated: 2026-10-29

## Current State

- Milestone: MVP — daily use
- Current step: `FIX-017` (started 2026-10-29)
- Next step: `REL-001` (`ready`)
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
| ALPHA-001 | done | 2026-08-01 | 2026-08-02 | Published [`v0.1.0-alpha.1`](https://github.com/ReflectionL/zulip-macos/releases/tag/v0.1.0-alpha.1) as a GitHub prerelease from exact commit `5d09b24c95960591d2f0ddfa2ab531587806da09`. GitHub Actions run [`30708009125`](https://github.com/ReflectionL/zulip-macos/actions/runs/30708009125) passed toolchain verification, 45 Rust core tests, 10 FFI actor tests, 41 Swift tests, and release builds. The 4,712,823-byte DMG is arm64-only, ad-hoc signed, unnotarized, version `0.1.0`, includes an `/Applications` alias, passes `hdiutil verify` and read-only mount/signature/launch smoke, and has SHA-256 `e709b5eae0275420fd8c8807877e36fe641eebc2768c496e860a7033771b0e03`. GitHub reports both DMG and checksum assets uploaded and the same DMG digest. This alpha does not close `REL-005`. | — | `819fd7c`; `ee6520f`; `5d09b24`; `v0.1.0-alpha.1` |
| FIX-001 | done | 2026-10-12 | 2026-10-12 | Root causes of the reported silent sign-out: (1) any non-retryable sync error (e.g. one event or user the client could not parse, or an unexpected HTTP status) made the Rust actor drop the account session without recovery; (2) the resulting `Failed(request_id: nil)` was swallowed by Swift because `nil == nil` matched the older-history branch, so the window stayed up but never updated; (3) launch never reconnected, so the first relaunch always showed signed-out. Fix: only HTTP 401 is fatal (`SyncError::Unauthorized`); other errors retry with backoff; malformed events become ignorable `Unknown` events; unusable bootstrap entries are skipped; Swift resets to sign-in with the reason, fixes the nil match, remembers the last account (server and email only, never the key) and reconnects from Keychain on launch; explicit Disconnect forgets it. Rust: `cargo clippy -D warnings` and 49 core + 10 FFI tests pass locally (Linux). Swift tests added; macOS 26 CI run [`38200213953`](https://github.com/ReflectionL/zulip-macos/actions/runs/38200213953) passed the full `./scripts/check.sh`. Residual: no manual multi-hour sign-in/relaunch smoke on a real Mac yet. | — | PR #2; `ddc5987` |
| FIX-002 | done | 2026-10-12 |  2026-10-12 | Added `SyncResumed` so the Swift connection state leaves `retrying` when polling succeeds without a snapshot (heartbeat-only batches previously left it stuck), a non-blocking "Reconnecting…" pill in the live window, an empty default server in the login form, and deletion of the Keychain key plus remembered account when the core ends a session after credential rejection. Rust clippy/tests pass locally; Swift verified by macOS CI: run [`38201133034`](https://github.com/ReflectionL/zulip-macos/actions/runs/38201133034) passed `./scripts/check.sh`. | — | PR #3; `35af719` |
| MVP-006 | done | 2026-10-12 | 2026-10-12 | Schema v2 adds `cached_state`; Rust saves the account identity, navigation snapshot (throttled to one write per 5 s) and each opened conversation (newest 300 messages, 40 conversations, pruned), serves them through `LoadCachedSession` and as an offline/failed-fetch fallback for `OpenConversation`, and deletes them on Disconnect. Drafts are stored per conversation (`SaveDraft`, `LoadDrafts`). Swift restores the last account on launch from cache, then connects with the Keychain key; transient failures keep the cached UI and retry with 5–60 s backoff; cached pages render in the existing offline state with a Reconnect action. Rust clippy and 51 core + 12 FFI tests pass locally; Swift verified by macOS CI. Closed after PR #4 passed macOS CI (`./scripts/check.sh`, 12 min). Not yet exercised on a real Mac. | — | PR #4 (`607fa88`) |
| MVP-007 | done | 2026-10-12 | 2026-10-12 | `NotificationPlanner` (pure, tested) decides which live messages notify: direct messages and mentions from other people, never muted conversations, never messages already read or sent by the user, never the conversation currently open in the active window; the first sync batch and cached data never notify. `MessageNotifier` posts local notifications through `UNUserNotificationCenter` (guarded so unbundled `swift run` builds do not trap), and activating one deep-links to the conversation. The Dock badge counts unseen notifications and clears when the app becomes active. Swift planner/routing tests run in macOS CI. | — | this PR |
| MVP-008 | done | 2026-10-12 | 2026-10-12 | `NavigationStore.selectRelative` and `selectQuickLink` back new shortcuts: ⌘1–⌘4 jump to Inbox/Mentions/Starred/Unread, ⌥⌘↑/↓ move through the sidebar with wraparound (topics skipped), alongside existing ⌘K, ⌘F, ⇧⌘L. The Settings window lists the shortcuts. Navigation tests cover wraparound and missing slots; the manual keyboard-only flow remains to be run on a Mac. | — | this PR |
| UPD-001 | done | 2026-10-12 | 2026-10-12 | Added `ReleaseVersion` (semver with prerelease ordering), `ReleaseFeed` (GitHub releases JSON to the newest installable release; drafts, missing checksum assets and non-GitHub hosts are skipped), `UpdateController` (launch check at most every 6 h, manual check, install state machine), and `SystemUpdateInstaller` (download, SHA-256 check, read-only mount, `ditto` stage beside the app, `codesign --verify`, bundle id and tag check, then a detached helper swaps the bundle after exit and relaunches). Packaging now stamps `ZulipReleaseTag` and `package-dmg.sh` verifies it. UI: app-menu ‘Check for Updates…’, a Settings ‘Updates’ section, and an ‘Update to vX…’ gear-menu entry. Known limit: the ad-hoc signature changes with every build, so macOS may ask for Keychain access again after an update until `REL-005` adds a stable Developer ID identity. Builds before the first release containing this change cannot self-update. macOS CI (`./scripts/check.sh`, run 38203793775) passed including the new version-ordering, release-selection, checksum, trust and controller tests; the real download-and-swap has not yet been exercised on a Mac. | — | PR #5 |
| FIX-003 | done | 2026-10-12 | 2026-10-12 | `handleSystemWake` retries immediately when the Mac wakes while the session is retrying; `os.Logger` breadcrumbs (retry, resume, core-ended session, wake) keep dynamic values private; `rust-toolchain.toml` pins 1.95.0 with clippy and rustfmt. Rust fmt, clippy and 52 core + 12 FFI tests pass under the pinned toolchain; the Swift wake test passed in macOS CI. | — | PR #5 |
| UI-008 | done | 2026-10-12 | 2026-10-12 | Colors now derive from the system (text/control backgrounds, label-tinted hover/selection/strokes, the user's accent color, system green/orange); the sidebar no longer paints an opaque background so the system material shows; control/panel radii are 10/16 pt; the sidebar divider, the inert account chevron, no-op Reply/Copy link/emoji controls and the “Return to send” hint were removed. Existing light/dark shell render tests pass in macOS CI. Not yet reviewed on screen: the owner should check the packaged build, especially the translucent sidebar behind the hidden titlebar. | — | PR #5 |
| FIX-004 | done | 2026-10-12 | 2026-10-12 | Started from the owner's alpha.3 test report (six issues, see `PLAN.md`). Rust side done: headings and inline emphasis parsed into native content, public avatar and organization icon fetched without credentials and cached, `avatar_url` and `realm_icon_url` carried from `register` through the sync snapshot and the offline cache. Presence added: `MessageClient::update_presence` posts the user's own state and derives everyone's from Zulip's 140 s rule; Swift polls once a minute (first request 1.5 s after the session starts) and shows the state on the direct-message dots. Opening a conversation now shows its cached copy at once (`LoadCachedConversation` / `CachedConversationLoaded`; the first fresh page replaces it and only that page marks messages read). Update checks hit GitHub's anonymous API limit on the owner's network ("GitHub is limiting requests"); the checker now reads `releases.atom` first and only then the REST API; automatic checks now count failed attempts toward the six-hour interval and a bare 403 is no longer reported as a rate limit. Direct messages are ordered by recent activity: the server's `recent_private_conversations` (requested at register, kept in the snapshot and offline cache) seeds the order, live one-to-one messages raise it (`directMessageRecency`), ties fall back to name; group conversations are not listed and do not count. Opening a conversation seen earlier this session now paints its remembered page synchronously (`recentPages`, 24 most recent) and the loading placeholder is delayed 400 ms, so quick opens never flash it. Quote and forward added: Rust `fetch_message_source` (raw Markdown via `apply_markdown=false`) over a new `FetchMessageSource`/`MessageSourceLoaded` bridge pair; Swift builds the Zulip quote block (`MessageQuote`), keeps it as a "Replying to …" chip above the composer for "Quote and reply" (prepended on send) and renders quote blocks in the timeline as a tinted card with the author's name (`QuoteAttribution`), and sends it to a chosen topic or person for "Forward message…". @-mention suggestions in the composer (`MentionAutocomplete`, keyboard-driven list above the field) and channel creation (Rust `create_channel` over `CreateChannel`/`ChannelCreated`, a New channel sheet from the sidebar header) added. Verification: Rust fmt, clippy `-D warnings` and `cargo test --workspace` passed locally (57 core tests, 12 ffi tests); macOS CI (`./scripts/check.sh`, 92 Swift tests) green on PR #7 head 1225b68 after one test fix (a direct-message ordering expectation); released as `v0.1.0-alpha.5` (DMG + SHA-256 uploaded by the release workflow). The owner installed alpha.5 by hand and approved closing the step. Residual: the alpha.3/alpha.4 updaters use the old API-based logic, so the new feed-based updater has not yet been exercised by an alpha-to-alpha in-app update (the next release will be its first real test); the Atom feed was not reachable from the build container, so it is validated only by unit tests. Not verified by tests: channel creation and forward against a live server, and the visual polish of the quote card and mention list (owner review on a Mac). | — | PR #7 (f3777e1) |
| FIX-005 | done | 2026-10-12 | 2026-10-12 | Started from the owner's alpha.5 test report (fourteen items, see `PLAN.md`). Root cause of the three flashes after sending (consecutive-message avatar, large Markdown message, quoted message showing its raw source): the local echo is a plain-text row with a negative ID that is removed and replaced by a new row with the server ID, so the row is rebuilt and Markdown first appears as raw text. Fix: `MessageViewData.rowID` keeps the echo's row for the server copy (carried through `removeConfirmedEchoes` and `mergeMessages`), `MessageViewData.isProvisional` plus `LocalEcho.needsServerRendering` show a "Sending…" placeholder for Markdown, and the timeline uses `defaultScrollAnchor(.bottom)` instead of an animated scroll after layout. Emoji: `content.rs` builds the glyph from the `emoji-<hex>[-<hex>…]` class of Zulip's emoji span (previously the `:name:` shortcode text was shown). Channel send: `sendText` and `retrySend` accept a `.channel` key and send to the empty topic; the empty topic is displayed through `TopicName.display` ("general chat"). `@` crash: not reproducible without a Mac; the most likely causes (input-method marked text and a stale trigger range) are removed, see `acceptMention` — to be confirmed by the owner. New: `MessageTimestamp`, `InterfaceScale` (+ commands, shortcuts, Settings row; `AppTheme.Typography` is now `@MainActor` and scaled, sidebar/palette row heights became minimums), breadcrumb `openParent`, `RenameChannelSheet` + Rust `rename_channel`/`RenameChannel`/`ChannelRenamed`, `PresenceDescription` + `last_active_at` through the presence bridge, 50-message pages. Verification so far: Rust fmt, clippy `-D warnings` and `cargo test --workspace` passed locally (58 core tests, 12 ffi tests). The Swift code could not be compiled in the cloud container; macOS CI (`./scripts/check.sh`) is the first compile. Closed after the cloud checks: `cargo fmt`, `cargo clippy -D warnings` and `cargo test --workspace` (59 core, 12 ffi tests) passed locally, and macOS CI (`./scripts/check.sh`) compiled the Swift code and passed on PR #9 (head 4852bd9). Follow-ups after the first push: text-size shortcuts are ⌘-only and server-rendered emoji now show their glyph (`content.rs`). `v0.1.0-alpha.6` was built by the Release workflow and the owner confirmed on a Mac that the fixes work. Residual: custom (image) emoji still show as `:name:`. | — | PR #9 (88bf301) |
| FIX-006 | done | 2026-10-12 | 2026-10-12 | Started from the owner's report that the organization icon no longer shows. Cause found in code: with the cached session shown first (FIX-004/005), the sidebar's `AvatarImage` asked for the icon and avatars before the Rust actor had an account session, got "no matching live account session", and never asked again because its task is keyed on the URL only. Fix in `LiveSessionViewModel.loadMedia` (defer until `hasLiveSession`, flush on `sessionStarted`, also retry earlier failures). Swift test `mediaDeferredUntilLiveSession` added; the Swift code could not be compiled in the cloud container, macOS CI (`./scripts/check.sh`, run 38234889084) compiled and passed on PR #12 head bbafde4. Not yet released: the fix reaches the owner with the next build, and the owner should confirm on a Mac that the organization icon and avatars show. | — | PR #12 (ce9ed2f) |
| FEAT-001 | done | 2026-10-12 | 2026-10-13 | Started from the owner's request for read receipts: small stacked round avatars at the bottom right of her newest sent message. Server API checked against Zulip's documentation: `GET /api/v1/messages/{id}/read_receipts` (feature level 137) returns `user_ids`, and fails with `BAD_REQUEST` when the organization disabled read receipts; readers who turned off sending receipts are omitted by the server. Rust (`fetch_read_receipts`, `FetchReadReceipts`/`ReadReceiptsLoaded`) is covered by a mock-server test and passes `cargo clippy -D warnings` and `cargo test --workspace` locally; the Swift side (`ReadReceipts.swift`, `ReadReceiptStack.swift`, polling in `ConversationSurface`, state in `LiveSessionViewModel`, tests `ReadReceiptTests` and `readReceipts`) cannot be compiled in the cloud container and macOS CI (run 38243574751) compiled and passed on PR #14 head 669395c. Released as `v0.1.0-alpha.8`; the owner installed it and confirmed on 2026-10-13 that the avatars show correctly. Defaults chosen: only the newest accepted sent message shows receipts; channels, topics and DMs/group DMs supported, other lists and notes-to-self not; up to 4 avatars then "+N"; one-third overlap. | — | PR #14 |
| FIX-007 | done | 2026-10-13 | 2026-10-13 | Started from the owner's alpha.8 report: no notifications, no unread counts, Inbox and Unread not useful, images displayed badly, plus a self-review. Causes found in code: (1) Zulip puts a new message's personal flags beside the message in the `message` event and the reducer only read the message object, so every live message had no `mentioned` flag; (2) unread state was never computed anywhere (the sidebar rows supported a count but nothing set it) and the Inbox that opened at every launch marked the newest 50 messages of the whole account read; (3) images linked from other sites were fetched from the link itself (often not an image, plain HTTP, or over the 2 MiB limit) and pictures without server dimensions were letterboxed in a 16:9 frame while tall screenshots grew to 1,100 pt. Fixes are described in the `PLAN.md` row. Rust passes `cargo clippy -D warnings` and `cargo test --workspace` locally (65 core, 12 FFI tests). The Swift side cannot be compiled in the cloud container and awaits macOS CI. Self-review fixes beyond the five reported items: `update_message` took the pre-move `stream_id` instead of `new_stream_id` and applied a topic move only to one message; "mark all as read" from another device did not clear the cache; opening any collection (Inbox/Mentions/Starred/Unread) or a conversation while the app was in the background marked messages read. | Beta 1 still failed to show pictures; continued and confirmed in `FIX-008`. | PR #15 (`e34f92b`); macOS 26 arm64 CI green; released as `v0.1.0-beta.1` (run 38341407322). |
| FIX-008 | done | 2026-10-13 | 2026-10-13 | Started from the owner's beta 1 report: pictures still not shown, no typing indicator, deleted/moved/renamed topics still in the sidebar. Causes found in code: (1) the sidebar topic list in Swift (`knownTopics`) only ever grew, and the Rust topic list was fetched once at session start, so nothing a rename, move or deletion removed ever left; (2) typing events were never subscribed to, and nothing announced the user's own typing; (3) pictures: the full path (HTML parsing, authenticated two-step download, public/proxied download, cache, decode, layout) was reviewed and no definite fault was found, so the cause remains unconfirmed; a download that was a web page was cached as if it were the picture, which would keep a broken picture across versions, and decode problems left no trace. Hardening and diagnostics are described in the `PLAN.md` row. Rust passes `cargo clippy -D warnings` and `cargo test --workspace` locally (69 core, 13 FFI tests). The Swift side cannot be compiled in the cloud container and awaits macOS CI. | None reported. | PR #17 (`cebfe23`); macOS 26 arm64 CI green. Released as `v0.1.0-beta.2` (run 38353745476); the owner replied "没问题" to the on-device checklist (pictures, typing indicator, topic cleanup). |
| FIX-009 | blocked | 2026-10-14 | — | Started from the owner's beta 2 report: direct messages sometimes load for a long time, Shift+Return crashes, "(edited)" label, the scope of system notifications, and (added later the same day) channel notification switches pictures still not showing, drag-and-drop file upload, and emoji reactions. Causes found in code are in the `PLAN.md` row (actor awaited fetches inline; a failed first page left the loading placeholder and flagged the connection as failed; stale selection and same-pass caret write in the Shift+Return handler). The notification range follows Zulip's own settings (the owner's choice on the decision card); because that means each channel needs its notifications turned on, the app now writes the channel and account-default settings back to Zulip. Pictures: the cause is still unconfirmed, but the media client's 12 s total deadline would fail any slow or large download and preview routes were not translated to the upload; the owner is asked for the text shown in the picture frame. This also closes the two known limitations about muted topics and per-channel notification settings. Verified so far: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` pass locally (72 core and 13 FFI tests). The Swift changes (composer line break, load failure and retry, "(edited)" row, `ChannelNotificationSettings`, planner and unread changes, tests) cannot be compiled in the cloud container; they are reviewed by hand and wait for macOS CI. Nothing is pushed yet: the owner is asked before the push. Residual: a moved message also shows "(edited)" because the server sets the same timestamp for moves; the topic-list refresh after a sync event still runs inside the actor loop and can delay commands (`REL-001`). | Waiting for the owner to confirm on a Mac (pictures still unconfirmed) | PR #21, #22 (`v0.1.0-beta.3`) |
| FIX-010 | blocked | 2026-10-14 | — | Started from the owner's beta 3 report: "(edited)" must follow the text on the same line, direct messages still sometimes fail to load, and notifications should have Zulip's three levels (Followed / Default / Muted) per topic. Causes and design are in the `PLAN.md` row. Direct-message root cause: the actor refreshed topic lists inline (network, every channel after a resync) so `OpenConversation` queued behind it; the 6 s cancel-and-retry also discarded nearly finished requests on slow links. Fixed with background topic refresh, a hedged first-page request and a 25 s Swift watchdog; new Rust tests prove a slow topic list and a stalled first page no longer hold up opening a conversation. Per-topic levels: `POST /user_topics` with `visibility_policy`, `TopicSnapshot.notification`, sidebar topic context menu and bell, planner/unread rules aligned with Zulip (followed always notifies, personal mention notifies in muted places, @all does not). Verified: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` locally (73 core, 15 FFI tests). The owner approved the push; macOS CI (133 Swift tests) failed once on the new open-watchdog test, which used `eventually` (it only yields) and did not wait real time; the test now sleeps, and CI on the fixed head passed. Merged and `v0.1.0-beta.4` dispatched; stays open until the owner confirms on a Mac; `blocked` while `FIX-011` is in progress because the owner's beta 4 report says direct messages and notifications still fail. Residual: renaming a topic still waits for its topic-list refresh (user-initiated); the per-topic API needs Zulip 7.0; the account setting for followed-topic notifications (`enable_followed_topic_desktop_notifications`) is assumed on. | — | PR #23 (`v0.1.0-beta.4`) |
| FIX-011 | blocked | 2026-10-14 | — | Started from the owner's beta 4 report: direct messages still sometimes do not load, screenshots do not show, notifications do not arrive, the general chat topic is stuck on Followed, and the chat should look like Element (name beside the avatar, time on hover, date separators). Causes and design are in the `PLAN.md` row; each repeated problem was approached from a new angle. Rust: sign-in runs beside the actor with held commands replayed; writes run as tasks with ordered sends; uploads keep the server's URL spelling; linked uploads get client previews; credentialed `/user_uploads` download fallback; long-poll grace; unread messages missed during a queue gap are fetched and notified; empty general-chat topic accepted. After the owner added that channels and topics also fail to load sometimes: the live snapshot keeps the newest 1,000 messages instead of every message since launch. Swift: newest snapshot of a burst applied once with queued events let through first, user list rebuilt only when it changes, Keychain save beside the event loop, fresh conversation surface per key (also fixes the owner's report that composer text followed her into other conversations), App Nap held off while signed in, alerts-off notice and Dock/sound fallback, Element-style message rows, sender colors and day separators. Verified: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings` and `cargo test --workspace` locally (79 core, 16 FFI tests). Swift is not compiled in the cloud; it was reviewed by hand and is first compiled by macOS CI. The owner approved the push; macOS CI failed once on the relaunch test ("A relaunch restores the last account from its saved API key"), which relaunched before the now background Keychain save had finished; the test now waits for the saved key, and CI on the fixed head passed (135 Swift tests). Merged and `v0.1.0-beta.5` released; `blocked` on the owner's confirmation on a Mac while `FIX-012` is in progress. Residual: messages missed during a queue gap are capped at 50 and need the server to keep them unread; the Element layout is a first pass for the owner to judge. | — | PR #25 (`v0.1.0-beta.5`) |
| FIX-012 | done | 2026-10-14 | 2026-10-14 | Started from the owner's note after `v0.1.0-beta.5` that notifications may be missing because the app never got macOS permission, and that an updated app should get the prompt by itself. Causes and design are in the `PLAN.md` row. Swift: `SystemMessageNotifier` asks once the app has launched (not only after sign-in), keeps the permission in an observable `NotificationStatus`, re-reads it when the app becomes active, records request and delivery errors, and offers a test notification and this app's System Settings page; the app owns the notifier and Settings gains a Notifications section. Drag-and-drop upload: the owner then relayed a friend's "error sending request" failure that could not be dismissed and whose Retry did nothing. Root cause: reqwest's read timeout (30 s on the transfer client) runs from the start of the request until the response begins, so it also covered sending the file; uploads now use a client without it and a 10 minute deadline, and transport errors name their cause. Swift: the upload state shows only in the conversation it belongs to (Retry used to be refused elsewhere), with a tooltip, a bordered Retry and a dismiss button. Pictures: links to uploads that have a preview are hidden (Rust `hide_previewed_upload_links`). Link cards (owner asked for Messages-style cards instead of bare links): Rust `ContentBlock::LinkPreview` from `div.message_embed` and from standalone links (`promote_standalone_links`), UniFFI `CoreContentBlock::LinkPreview` (field `page_description`, checked against locally generated Swift bindings), Swift `LinkPreviewCard` with a LinkPresentation fetch through `LinkMetadataStore` and a Settings › Link Previews toggle. Also made `cached_session_and_conversation_are_readable_without_a_live_session` wait for the background topic refresh, which it raced under load (failed once locally). Verified: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` locally (82 core, 16 FFI tests; the full suite three times before the link cards). Swift is not compiled in the cloud; reviewed by hand, first compiled by macOS CI. Merged and released as `v0.1.0-beta.6`; the owner confirmed it on a Mac (2026-10-14). | — | PR #26 (`v0.1.0-beta.6`) |
| FIX-013 | done | 2026-10-14 | 2026-10-14 | Started from the owner's report that a message arriving after the screen locks leaves no red Dock badge (and no notification). Cause and design are in the `PLAN.md` row: a locked screen leaves the frontmost app active, so the open conversation was still treated as being read. Swift: new `UserAttention` (lock/unlock, display sleep/wake, login-session switch) and `LiveSessionViewModel.isUserPresent()` replacing `isApplicationActive()` for mark-read, the open-conversation notification skip, read-receipt polling and presence; the open conversation is refreshed when the user returns. Tests added in `LiveSessionTests` and `NotificationTests`. Composer: attach, text and send share one row; the attach button uses a new `CircleHoverButtonStyle` (28 pt circle, hover and pressed fill). Date separators: `MessageTimestamp.dayLabel(for:now:)` (system calendar, auto-updating), with the surface's reference moment renewed on `NSCalendarDayChanged`, `NSSystemTimeZoneDidChange`, activation and wake; hover time keeps AM/PM on 12-hour systems. Tests in `InterfaceTextTests`. Status and invisible mode: Rust `UserStatus`/`UserStatusUpdate`, `SyncEvent::UserStatusChanged`/`InvisibleChanged`, `parse_user_statuses`, `MessageClient::set_user_status`/`set_invisible`, FFI `CoreCommand::SetUserStatus`/`SetInvisible`, `CoreUserStatus`, snapshot `user_statuses`/`invisible` (cached); Swift `LiveUserStatus`, `UserStatusDisplay`, `ProfileStatusPopover`, `UserStatusEditor`, status emoji in the sidebar and message headers, `conversationHeaderStatus(for:)`. Verified locally: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` (84 core, 16 FFI tests). Swift is not compiled in the cloud; reviewed by hand, first compiled by macOS CI. Hover action bar moved above the row's top-right corner (`alignmentGuide(.top)`, 10 pt overlap) with its own hover state so it does not cover read receipts; Swift only, reviewed by hand. Hover source label: `LiveSessionViewModel.messageSourceLabel(for:in:)`, `ConversationSurface.sourceLabel`, test `messageSourceLabel`. Owner confirmed `v0.1.0-beta.7` on 2026-10-14. | — | — |
| FIX-014 | done | 2026-10-15 | 2026-10-15 | Started from the owner's report that the Dock badge sometimes still shows 1 after everything is read; the same batch also covers her report that pasting long text lags her request for a compact message density, Markdown table rendering, a fade where messages scroll under the toolbar, and her request to show the whole message with a gray "Sending…"/"Editing…" at its end. Cause and design are in the `PLAN.md` row: the unread index only follows server events, and a late fetch or a lost event could leave one message unread with nothing able to clear it. Rust: `SyncReducer.recently_read` (bounded, applied in `add_fetched_messages`), `SyncReducer::mark_read_locally` / `SyncSession::mark_read_locally`, FFI `MarkedRead` actor input and `AccountSession.marked_read`, so a successful mark-read updates the counts and publishes a snapshot. Tests `a_fetch_that_answers_after_the_read_does_not_make_the_message_unread_again` and `a_read_this_client_made_clears_a_message_the_queue_never_cleared`. Verified locally: `cargo fmt`, `cargo clippy --workspace -- -D warnings`, `cargo test --workspace` (86 core, 16 FFI tests); the Swift existing draft tests were checked by reading, not run. Paste lag (Swift, reviewed by hand, first compiled by macOS CI): `LiveSessionViewModel.drafts` is `@ObservationIgnored` with `draftsLoadRevision`, the draft/typing `onChange` moved from `ConversationSurface` into `ComposerView`, `canSend` uses `contains { !$0.isWhitespace }`. Sending/editing status: `MessageRow.trailingStatus` ("Sending…", "Editing…", "(edited)") continues the last paragraph or takes its own line, the Markdown placeholder (`showsPlaceholder`) is gone, `failureRow` shows "Not sent" or the failure with retry and cancel icons; new `LiveSessionViewModel.cancelSend` / `cancelMessageAction` plumbed through `ConversationSurface` and `LiveViews`; test `cancelledSendLeavesTheTimeline`. Message density: new `DesignSystem/MessageDensity.swift` (`MessageDensity`, `MessageDensityPreference`), `MessageRow` padding reads it, picker in `TextSizeSettingsSection`, README line; tests `MessageDensityTests`. Tables: Rust `ContentBlock::Table` / `TableAlignment` (`parse_table`, `cell_alignment`, `trim_inline` in `content.rs`), FFI `CoreContentBlock::Table`, Swift `ContentBlock.table` / `MessageTableView`; Rust tests `tables_keep_header_rows_alignment_and_inline_cells`, `a_table_without_a_header_row_has_none_and_an_empty_one_stays_readable`, `tables_are_bounded_in_rows_and_columns`; Swift fixture and `MessageContentTests` table cases. Top fade: `ConversationSurface.toolbarInset` and `TimelineEdgeFade` mask (top band under the toolbar and a 16 pt fade above the composer, with matching bottom padding); the typing indicator lost its capsule and sits in that band (`typingIndicatorDrop`) on the timeline scroll view (Swift only, reviewed by hand; the geometry assumption that the scroll view's frame reaches under the toolbar is unverified until the owner runs it). Rust re-verified after the table change: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` (89 core, 16 FFI tests). LaTeX: Rust `math.rs` (TeX parser, `MathNode`, `to_linear`), `InlineContent::Math` / `ContentBlock::Math` in `content.rs` (`parse_math`, `paragraph_blocks`; annotation text read directly because `descendant_text` skips everything under `<math>`), FFI `CoreMathNode` and friends; Swift `MathNode`, bridge mapping, `Conversation/MathView.swift` (layouts and shapes), `MessageContentView` cases, fixture and `mathText` test. Closing evidence: macOS CI on PR #28 first failed to compile (`TableColumnAlignment` clashes with the SwiftUI type, renamed `TableCellAlignment`), then passed on 448e47b; the composer card padding was set to 10 pt after the owner found 8 pt too tight; release workflow run 38678027777 published `v0.1.0-beta.8` (DMG and SHA-256); the owner installed it and confirmed on 2026-10-15. Rust verified: `cargo fmt`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` (102 core, 17 FFI tests); the Swift layout code is unverified until macOS CI compiles it and the owner looks at real formulas (baseline of fractions and scripts, bracket height, root sign shape and the fit of `ViewThatFits` are guesses from reading). Composer height: `ComposerView` card padding is 12 pt horizontal and 10 pt vertical (was 12 all round; 8 pt was too tight for the owner); Swift only, unverified until CI and the owner look. Open question for the owner (badge): group direct messages and DMs with deactivated people count in the badge but have no sidebar row. | — | PR #28 (`v0.1.0-beta.8`) |
| FIX-015 | done | 2026-10-15 | 2026-10-15 | Started from the owner's report that the composer keeps the text after sending (`v0.1.0-beta.8`). Cause and design are in the `PLAN.md` row: a regression from `FIX-014`'s unobserved `drafts`; the surface's `onChange(of: initialDraft)` restored the just-sent text because the view was re-evaluated by the local echo before the composer's `onChange` had cleared the saved draft. Fix (Swift only, reviewed by hand, first compiled by macOS CI): `ConversationSurface.sendDraft` calls `draftChanged?("")` before clearing and sets `acceptsSavedDraft = false`, which the `initialDraft` handler checks. Review of `FIX-012` to `FIX-014` at the owner's request (Rust and Swift diffs read; `cargo test --workspace` passes, 102 core and 17 FFI tests): "Mark as Unread" in an open conversation was undone by the refresh that follows it (`keptUnreadMessageIDs`, test `markedUnreadIsKept`), and status text was limited by characters instead of code points (`UserStatusDisplay.clampedText`, cases in the status test). Composer height (owner): `ComposerMetrics` buttons 26 pt and vertical padding 8 pt, one-line composer 42 pt (was 48). Closing evidence: macOS CI on PR #31 passed on the first run (9505809, check "macOS 26 arm64"), PR #31 merged as 55f1a4b, release workflow run 38682783469 published `v0.1.0-beta.9` (DMG and SHA-256), and the owner confirmed the batch and the composer height on 2026-10-15. | — | PR #31 (`v0.1.0-beta.9`) |
| FIX-016 | done | 2026-10-15 | 2026-10-15 | Welcome screen rework at the owner's request (design and cause in the `PLAN.md` row). Swift only, reviewed by hand, not yet compiled (cloud session; macOS CI is the first compile). New `app/Sources/ZulipMac/AppShell/WelcomeView.swift` (`WelcomeView` in the connected window's `WindowShellView` with a `WelcomeSidebar` and the shared top bar, shared `LoginForm`); `conversationToolbar` gained `showsDetails`; `AppRootView` and `LiveLoginView` in `LiveViews.swift` use them; `LiveSessionViewModel.hasSavedAccount`. Tests added: `welcomeRenders`, `savedAccountFlag`. Closing evidence: macOS CI on PR #35 passed on the first run (c769512, check "macOS 26 arm64"), PR #35 merged as 88b2e43, release workflow run 38692836796 published `v0.1.0-beta.10` (DMG and SHA-256), and the owner confirmed the welcome screen on a Mac on 2026-10-15. | — | PR #35 (`v0.1.0-beta.10`) |
| FIX-017 | in_progress | 2026-10-29 | — | Interface polish at the owner's request (causes and design in the `PLAN.md` row; design note with palette and mock-up images in the project files, `ui-polish/`). Swift only, reviewed by hand, not yet compiled (cloud session; macOS CI is the first compile). Rewritten `DesignSystem/AppTheme.swift` (tokens, `Color.dynamic`, `SurfaceElevation`, `Motion`, `motion(_:value:)`); new `DesignSystem/HoverFillButtonStyle.swift` and `Sidebar/ChannelColor.swift` (`ChannelColor`, `OKLCHColor`); `SenderColor` palette replaced; call sites in `Conversation/`, `Sidebar/`, `Navigation/`, `Live/`, `AppShell/`, `Status/` moved to the tokens; `.tint` in `ZulipMacApp`. Tests: `DesignTokenTests` gains radius/height scales, `senderColorContrast`, `channelColorParsing`, `channelColorNormalization`. Contrast figures were computed with the WCAG formula (Python, same OKLab math) before writing the Swift. | — | — |

Later milestones remain defined in `PLAN.md` and will be added here when they
become active; completed rows are never removed.

## Work Log

### 2026-10-29

- Began `FIX-017`: the owner finds the interface cheap-looking; wrote a design note (inventory of colors, type, radii, shadows, spacing, states and motion, plus a token proposal), the owner chose a fixed indigo accent, and the tokens are applied locally, not pushed.

### 2026-10-15

- Closed `FIX-016` (merged in PR #35, `v0.1.0-beta.10` released and confirmed by the owner on 2026-10-15). No step is in progress; `REL-001` is next.
- Began `FIX-016`: the signed-out window was the fixture demo with a separate sign-in sheet; replaced it with `WelcomeView` and a shared `LoginForm` in the connected window's styling, locally, not pushed.
- Closed `FIX-015` (merged in PR #31, `v0.1.0-beta.9` released and confirmed by the owner on 2026-10-15). No step is in progress; `REL-001` is next.
- Began `FIX-015`: the composer kept the sent text after sending (regression of `FIX-014`'s draft change); fixed locally in `ConversationSurface.sendDraft`, not pushed.
- `FIX-015` review of the beta.6 to beta.8 changes: kept "Mark as Unread" from being undone by the conversation refresh, and limited status text by code points; not pushed.
- Closed `FIX-014` (merged in PR #28, `v0.1.0-beta.8` released and confirmed by the owner on 2026-10-15). No step is in progress; `REL-001` is next.
- Began `FIX-014` from the owner's reports of a Dock badge stuck on 1, of lag when pasting long text, and of how sending and editing status should show. Closed `FIX-013` (`v0.1.0-beta.7` confirmed by the owner). Nothing is pushed until the owner agrees; `v0.1.0-beta.8` follows CI.

### 2026-10-14

- Began `FIX-013` from the owner's report that no Dock badge appears for messages that arrive while the screen is locked. Closed `FIX-012` (merged in PR #26, `v0.1.0-beta.6` confirmed by the owner). Nothing is pushed until the owner agrees; `v0.1.0-beta.7` follows CI.
- Began `FIX-012` from the owner's note after `v0.1.0-beta.5` (ask for notification permission at launch so an update gets it by itself, show the permission in Settings; drag-and-drop uploads failing with "error sending request" and an undismissable error; hide a picture's link when its preview shows). `FIX-011` is `blocked` on her confirmation. The owner is asked before the push; `v0.1.0-beta.6` is built after CI passes and the PR merges.
- Merged `FIX-011` (PR #25, green macOS CI after one test fix) and released `v0.1.0-beta.5` with `docs/release-notes/v0.1.0-beta.5.md`.
- Began `FIX-011` from the owner's beta 4 report (direct messages, screenshots, notifications, the general chat bell, then an Element-style chat layout). `FIX-010` is `blocked` on her confirmation so only one step is in progress. One branch and one CI run; the owner is asked before the push, and `v0.1.0-beta.5` is built after CI passes and the PR merges.
- Merged `FIX-010` (PR #23, green macOS CI after one test fix) and dispatched the `v0.1.0-beta.4` release with `docs/release-notes/v0.1.0-beta.4.md`. `FIX-010` stays `in_progress` until the owner confirms on a Mac (inline "(edited)", direct messages loading, topic Follow / Default / Mute).
- Began `FIX-010` from the owner's beta 3 report (inline "(edited)", direct-message loading root cause, per-topic Followed / Default / Muted). `FIX-009` is `blocked` on her confirmation on a Mac so only one step is in progress. One branch, the owner is asked before the push, the release is built after CI passes and the PR merges.
- Merged `FIX-009` (PR #21, green macOS CI on the first Swift compile of the batch). Release notes now come from `docs/release-notes/<tag>.md` (Chinese Fixes / New features) and `release.yml` reads that file; `v0.1.0-beta.3` is built right after this lands. `FIX-009` stays `in_progress` until the owner confirms on a Mac.
- Added emoji reactions to `FIX-009` (quick row + searchable list, grouped chips with counts, toggle). Rust keeps `emoji_code`/`reaction_type`; Swift groups by code. The bundled emoji table uses names from the Python `emoji` package (gemoji-style aliases first); Zulip resolves any name it knows, so a rare emoji the server does not recognise shows an "Action failed" with Retry rather than silently failing. Not compiled in the cloud.
- Added drag-and-drop upload to `FIX-009` (existing picker upload reused; drop target on the conversation, one-at-a-time queue, failure clears it). Not compiled in the cloud; whether a drop over the text field itself is taken by the field (inserting a path) rather than the conversation pane can only be checked on a Mac.
- Began `FIX-009` from the owner's beta 2 report (slow direct-message loading, Shift+Return crash, "(edited)" label, notification scope); one PR, one CI run, the owner is asked before the push, and the release is built right after CI passes and the PR merges.

### 2026-10-13

- Merged `FIX-007` (PR #15, green macOS CI) and released `v0.1.0-beta.1` on the owner's request; `FIX-007` is `blocked` on her on-device confirmation.
- Began `FIX-008` from her beta 1 report (pictures, typing indicators, stale topics); one PR, one CI run, no release build until she says to build.
- Began `FIX-007` from the owner's alpha.8 report (notifications, unread counts, sidebar Inbox/Unread removal, images, self-review); one PR, one CI run, no release build until the owner says to build.
- Released `v0.1.0-beta.2` (`FIX-008`) on the owner's "构建"; she confirmed the checklist ("没问题"), so `FIX-007` and `FIX-008` are `done`. From now on releases are built right after CI passes and the PR merges; she is asked before code is pushed.
- Marked `FEAT-001` `blocked` on the owner's on-device confirmation so that only one step is `in_progress`.

### 2026-10-12

- Began `FEAT-001` (read receipts) on the owner's request; one PR, one CI run, no release build until the owner asks.
- Began `FIX-006` after the owner reported the organization icon missing; traced to media requests made before the live session exists failing permanently.
- Began `FIX-004` from the owner's alpha.3 test report: avatars, organization icon, send flash, message grouping, composer line breaks and Markdown rendering, batched into one PR and one CI run.
- Delivered `UPD-001` (in-app updates), `FIX-003` (wake recovery, diagnostics, pinned toolchain) and `UI-008` (minimalist system-native visual pass) in PR #5 alongside `MVP-007`/`MVP-008`; one macOS CI run covered the whole batch. Remaining backlog: Chinese localization of error text, `REL-001`–`REL-005`.
- Closed `MVP-006` (PR #4, green macOS CI) and delivered `MVP-007` notifications and `MVP-008` keyboard completion together with a sync correctness fix: the live reducer now applies `update_message_flags` and `reaction` events, conversations are only refetched when the changed message belongs to them, and topic discovery fetches 12 channels concurrently. `REL-001` is now `ready`.
- Closed `FIX-002` (PR #3, green macOS CI) and began `MVP-006`: offline reading from a Rust-owned cache plus persisted drafts.
- Closed `FIX-001` after PR #2 merged with green macOS CI; began `FIX-002` (connection status and sign-in hygiene), the first item of the optimization backlog the user asked to work through.
- Began `FIX-001` after a user report that the app signs out by itself some time after login. Traced it to fatal sync errors silently ending the Rust session, a Swift `nil == nil` match that hid the error, and no credential restore on launch. See the step row for the fix; Swift verification is pending macOS CI.

### 2026-08-02

- Closed `ALPHA-001`. GitHub Actions run `30708009125` is green and the exact
  verified commit `5d09b24c95960591d2f0ddfa2ab531587806da09` is published as
  prerelease `v0.1.0-alpha.1`. GitHub asset inspection reports the DMG uploaded
  at 4,712,823 bytes with SHA-256
  `e709b5eae0275420fd8c8807877e36fe641eebc2768c496e860a7033771b0e03`,
  matching the local checksum. The final image passed read-only mount,
  `/Applications` alias, strict signature, arm64 architecture, version, and
  packaged-app launch inspection. `MVP-006` remains the next ready step.
- `ALPHA-001` local release verification passed, including the full test suite,
  strict ad-hoc signature, arm64-only executable, valid/read-only DMG, checksum,
  and launching the packaged app directly from the mounted image.
- GitHub CLI was reauthorized for `ReflectionL`. The pushed release-source run
  failed before tests because the clean macOS 26 runner lacked `rg`; updated CI
  to install `ripgrep` before `bootstrap.sh`. Publication remains pending until
  the replacement run is green.
- The replacement CI reached the actor suite and exposed a timing-dependent
  mock-server assumption: cancellation of the continuous event poll can leave
  an accepted socket with no HTTP bytes. Topic and message-action mocks now
  ignore those empty transport connections. The affected test passes 20/20
  consecutive local runs; `./scripts/check.sh` again passes 45 Rust core, 10
  FFI actor, and 41 Swift tests.

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

- The live snapshot still carries every message received since launch and is
  copied across FFI on each change; a busy organization will slow down over a
  long session (`REL-001`).
- Channel typing notifications need a Zulip 9 server (feature level 215 or newer);
  older servers only report direct-message typing.
- A message that was moved shows "(edited)" because the server sets the same
  `last_edit_timestamp` for moves and content edits.

## Open Decisions

- Final public product name and icon are intentionally deferred until the UI
  prototype has a stable visual identity.

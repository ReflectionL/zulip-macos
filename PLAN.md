# Zulip Mac Development Plan

Last updated: 2026-10-12

## Current Milestone

**Milestone MVP — Daily use**

Success means two users can complete one week of ordinary messaging without
the official client for basic operations.

## Status Values

- `planned` — defined but dependencies are not yet complete.
- `ready` — dependencies are complete and the step may start.
- `in_progress` — the only active implementation step.
- `done` — all acceptance criteria and verification passed.
- `blocked` — cannot progress; the reason is recorded in `TRACKER.md`.

Only one step may be `in_progress`.

## Architecture Decisions

- Target macOS 26+, arm64 only, Swift 6 strict concurrency.
- Use SwiftUI for the application shell and AppKit only where macOS text,
  selection, window, or focus behavior requires it.
- Use Rust for API, sync, domain state, persistence, content normalization, and
  authenticated media caching.
- Use UniFFI for a deliberately small bridge: synchronous command submission,
  immutable records, and a `Send + Sync` event callback.
- Keep credentials in Keychain and only in Rust process memory while a session
  is active.
- Use SQLite for account-scoped non-secret cache data and drafts.
- Use fixture and live implementations of the same `CoreClientProtocol`.

Bridge-facing types are `CoreClientProtocol`, `CoreCommand`, `CoreEvent`,
`ConversationKey`, `SidebarSnapshot`, `ConversationPage`, `MessageViewData`,
and `ContentBlock`.

## Milestone D — Documentation and Foundation

| ID | Step | Deliverable and acceptance criteria | Depends on | Verification | Status |
| --- | --- | --- | --- | --- | --- |
| DOC-001 | Project control documents | Root `AGENTS.md`, `PLAN.md`, and `TRACKER.md` exist, link to one another, define step lifecycle, and contain no broken local links. | — | `./scripts/check-docs.sh` once DOC-002 supplies scripts; initially inspect links with `rg`. | done (2026-07-30) |
| DOC-002 | Repository skeleton | Initialize Git; add directory layout, `.gitignore`, Apache-2.0 `LICENSE`, README, scripts directory, and documentation checker. | DOC-001 | `git status --short`; `./scripts/check-docs.sh` | done (2026-07-30) |
| FND-001 | Swift and Rust projects | A macOS 26 arm64 SwiftUI app and Cargo workspace build independently. | DOC-002 | `cargo test --workspace`; `swift test --package-path app` | done (2026-07-30) |
| FND-002 | Reproducible automation | Local build/check scripts and GitHub Actions run formatting, Rust tests, Swift tests, and release builds. | FND-001 | `./scripts/check.sh`; validate workflow syntax | done (2026-07-30) |
| FND-003 | Minimal Rust–Swift loop | Swift submits a typed command to Rust; Rust returns a typed event through UniFFI; a smoke test verifies the round trip. | FND-002 | `./scripts/test.sh`; run the macOS debug app | done (2026-07-30) |

Milestone exit: all D/FND steps are `done`; the fixture-backed application
launches through the documented build path.

## Milestone UI — Codex-Style Prototype

| ID | Step | Deliverable and acceptance criteria | Depends on | Verification | Status |
| --- | --- | --- | --- | --- | --- |
| UI-001 | Design tokens | Semantic colors, typography, spacing, radii, strokes, hover, focus, and selection tokens work in light/dark appearances. | FND-003 | Swift tests and preview matrix | done (2026-07-30) |
| UI-002 | Window shell | Resizable/collapsible 240–320 pt sidebar and native main content shell; no fixed third column. | UI-001 | Manual window-size matrix | done (2026-07-30) |
| UI-003 | Sidebar | Inbox, Mentions, Starred, Drafts, Channels, DMs, unread badges, hover, selection, and section collapse. | UI-002 | Fixture UI tests | done (2026-07-30) |
| UI-004 | Navigation | Channel/topic/DM routing and searchable command palette using stable `ConversationKey` values. | UI-003 | Navigation and keyboard tests | done (2026-07-30) |
| UI-005 | Conversation surface | Virtualized timeline, path header, scroll behavior, message actions, and fixed composer. | UI-004 | 1,000-message fixture performance check | done (2026-07-30) |
| UI-006 | Native fixture content | Text, link, mention, emoji, quote, list, code, and image blocks render without WebKit. | UI-005 | Content snapshot tests | done (2026-07-30) |
| UI-007 | State and accessibility pass | Light/dark, empty/loading/error/offline states, keyboard traversal, text selection, and baseline VoiceOver labels. | UI-006 | UI snapshot and manual accessibility checks | done (2026-07-30) |

Milestone exit: the app demonstrates its complete primary navigation and
message interaction using fixtures through `CoreClientProtocol`.

## Milestone CORE — Live Zulip Vertical Slice

| ID | Step | Deliverable and acceptance criteria | Depends on | Verification | Status |
| --- | --- | --- | --- | --- | --- |
| CORE-001 | Server discovery | Normalize a server URL, require trusted HTTPS outside local development, fetch `server_settings`, and record feature level/auth capabilities. | UI-007 | Mock-server success/error/TLS tests | done (2026-07-30) |
| CORE-002 | Authentication | Password-to-API-key and direct API-key login; Keychain persistence; secrets redacted from logs/errors. | CORE-001 | Mock auth and Keychain tests | done (2026-07-30) |
| CORE-003 | Persistence | Versioned SQLite schema for accounts, users, channels, topics, messages, unread state, drafts, and sync metadata. | CORE-002 | Migration, isolation, and rollback tests | done (2026-07-30) |
| CORE-004 | Initial sync and events | Register event queue, reduce initial state, long-poll heartbeats/events, and publish batched snapshots. | CORE-003 | Fixture protocol and reducer tests | done (2026-07-30) |
| CORE-005 | Recovery | Backoff with jitter, duplicate filtering, bad queue recovery, server restart handling, and full resync. | CORE-004 | Deterministic disconnect/restart tests | done (2026-07-30) |
| CORE-006 | Live message loop | Login, initial sync, open conversation, receive/send text, and update read state against Zulip Cloud. Self-hosted protocol compatibility is covered by deterministic mock servers; a real HTTPS self-hosted smoke remains a release gate in `REL-005`. | CORE-005 | `./scripts/live-smoke.sh` against Cloud; running-app login/UI/Keychain smoke; mock authentication, queue, recovery, message, and read-state tests | done (2026-07-31) |

Milestone exit: Zulip Cloud continuously sends and receives messages, restores
saved credentials, and recovers from ordinary network interruption. Standard
self-hosted compatibility is covered by deterministic protocol tests until the
required live release smoke in `REL-005`.

## Milestone MVP — Daily Use

| ID | Step | Deliverable and acceptance criteria | Depends on | Verification | Status |
| --- | --- | --- | --- | --- | --- |
| MVP-001 | Browsing | Live combined feed, channel, topic, direct-message, mentions, starred, and unread destinations use stable `ConversationKey` values and immutable account-scoped pages. Users can load older history without duplicating or reordering messages, while preserving the newest-page live refresh path. The Swift sidebar and quick switcher expose every destination without performing network work on the main actor. | CORE-006 | Rust API pagination/narrow tests; FFI actor snapshot tests; Swift navigation/view-model tests; `./scripts/check.sh`; running-app browse and load-older smoke | done (2026-07-31) |
| MVP-002 | Search | Submit bounded non-empty queries through Zulip's server-side `search` narrow and return immutable account-scoped results. Each result carries a stable conversation key and message anchor; selecting it loads an anchored conversation page, preserves normal live refresh behavior, and visibly focuses the target message. Empty queries, stale responses, errors, and no-result states are deterministic, and no network or parsing work runs on the Swift main actor. | MVP-001 | Rust search/narrow/anchor tests; FFI actor result tests; Swift search state/navigation tests; `./scripts/check.sh`; running-app Cloud search and result-focus smoke | done (2026-07-31) |
| MVP-002A | Topic workflow | Expose each channel's topics inline with accessible expand/collapse and stable account-scoped routing. From a channel, users can start a validated new-topic draft and create the topic by sending its first message. From a topic, users can rename the whole topic; from a channel message, users can move that message to an existing or new topic in the same channel. Rename uses Zulip's `change_all` propagation and move uses `change_one`; UI state is updated only after correlated success, while errors remain retryable and never block the main actor. | MVP-002 | Rust topic-update protocol/validation tests; FFI actor command/event tests; Swift sidebar/topic-action state tests; `./scripts/check.sh`; running-app topic browse/create-draft/dialog smoke; mock rename/move write smoke | done (2026-08-01) |
| MVP-003 | Message actions | Implement real send, content edit, delete, emoji reaction, star/unstar, and read/unread writes. Every user-visible write has correlated pending state; success reconciles with server state, while failure rolls back or remains explicitly retryable. No failed write is replayed automatically, and no network work runs on the Swift main actor. | MVP-002A | Rust write protocol/validation tests; FFI actor correlation tests; Swift pending/success/failure/retry tests; `./scripts/check.sh`; disposable self-DM Cloud action smoke | done (2026-08-01) |
| MVP-005 | Zulip content | Parse untrusted Zulip HTML in Rust into native account-safe `ContentBlock` values for paragraphs, links, mentions, emoji, quotes, lists, code, and images. Reject unsafe URL schemes and executable/unknown markup, bound parser output, preserve readable plain text for malformed input, and never render live HTML in WebKit. | MVP-003 | Rust malformed/adversarial HTML corpus; FFI content mapping tests; Swift native-render tests; `./scripts/check.sh`; running-app rich-message smoke | done (2026-08-01) |
| MVP-004 | Files and media | Upload one picker-selected regular file up to 25 MiB through Zulip's authenticated `user_uploads` endpoint, then insert the server-normalized Markdown link into the active composer without sending automatically. Resolve only same-origin `/user_uploads/` message media through the authenticated temporary-URL API, bound each download to 32 MiB, write atomically into an opaque account-partitioned cache, and expose only cache-owned `file:` URLs to Swift. Upload/download failures remain visible and explicitly retryable; Swift performs file selection and off-main-actor native image decoding. Resumable TUS uploads and native audio/video playback remain deferred. | MVP-005 | Rust upload multipart/limit and authenticated cache isolation/path/size/atomicity tests; FFI actor correlation tests; Swift picker/upload/insertion/media state and native image tests; `./scripts/check.sh`; disposable Cloud attachment send/render/download smoke | done (2026-08-01) |
| MVP-004A | UI chrome polish and app icon | Tighten the empty area above the sidebar content; move connect/disconnect from the main toolbar into the bottom-left settings menu; let the conversation path header occupy the released top position; remove the separator above the fixed composer; and ship an original minimalist macOS app icon in the packaged bundle. Existing fixture/live behavior, sidebar collapse, keyboard access, and light/dark readability remain intact. | MVP-004 | Swift layout, command, accessibility, light/dark render, and app-identity tests; `./scripts/check.sh`; package/signature inspection and running-app visual smoke | done (2026-08-01) |
| MVP-004B | Titlebar visual correction | Restore a collision-free sidebar top inset below the macOS traffic lights. Replace the oversized Liquid Glass sidebar toggle with a compact flat icon that preserves collapse/expand behavior and keyboard accessibility. Keep the conversation breadcrumb in the top row without a Liquid Glass capsule, preserve its original flat typography, and force search/topic/detail actions to the far-right toolbar group. The correction must be accepted from fresh running-app screenshots at standard and compact widths, not accessibility output alone. | MVP-004A | Swift spacing, sidebar-toggle, accessibility, and light/dark render tests; `./scripts/check.sh`; fresh packaged-app screenshots at standard and compact widths; sidebar collapse/expand smoke | done (2026-08-01) |
| ALPHA-001 | GitHub alpha package | Produce a reproducible Apple Silicon release app and compressed DMG for `v0.1.0-alpha.1`, including an `/Applications` alias and SHA-256 checksum. The app must retain its icon and version metadata, pass strict ad-hoc signature verification, contain only arm64 code, and launch on this macOS 26 host. The DMG must pass `hdiutil verify` and read-only mount inspection. Publish the exact verified commit and DMG as a GitHub prerelease with explicit macOS 26/arm64, ad-hoc-signing, notarization, and unfinished-MVP limitations. This alpha does not satisfy the later signed/notarized/self-hosted `REL-005` beta gate. | MVP-004B | `./scripts/check.sh`; `./scripts/package-dmg.sh release v0.1.0-alpha.1`; `codesign --verify --deep --strict`; `lipo -archs`; `hdiutil verify`; read-only DMG mount and packaged-app launch smoke; GitHub prerelease/asset inspection | done (2026-08-02) |
| FIX-001 | Session persistence and sync resilience | Fix the report that a signed-in session ends on its own. Only an HTTP 401 may end a live sync session; every other registration/poll failure retries with backoff, an uninterpretable event or bootstrap entry is skipped instead of poisoning the queue, a core-ended session returns to sign-in with its reason instead of being mislabeled as an older-history failure, and the last account is reconnected from its Keychain API key on launch unless the user chose Disconnect. | ALPHA-001 | Rust sync tests for 401, retryable errors, malformed events and lenient bootstrap; Swift restore/disconnect/core-ended-session tests; `./scripts/check.sh` | done (2026-10-12) |
| FIX-002 | Connection status and sign-in hygiene | Show a non-blocking "Reconnecting…" indicator while sync retries and clear it as soon as polling succeeds again (new `SyncResumed` core event). Remove the hard-coded default organization from the login form. When the server rejects the key, delete that Keychain item so a dead key is not offered again. | FIX-001 | Rust FFI tests; Swift retry-clears, core-ended-session and login-default tests; `./scripts/check.sh` | done (2026-10-12) |
| MVP-006 | Offline reading and drafts | Cached recent conversations and local drafts work offline; writes require explicit retry after reconnect. Delivered as: Rust persists the last navigation snapshot and each opened conversation per account (`cached_state`, schema v2, bounded and pruned) and serves them when no live session exists or a fetch fails; Swift shows the cached account and conversations immediately on launch, marks them offline with a disabled composer and a Reconnect action, retries with backoff, and persists composer drafts per conversation. Disconnect forgets the cache. | MVP-004B | Offline/relaunch tests | done (2026-10-12) |
| MVP-007 | Notifications | Local notifications and badges for DMs/mentions; activation deep-links to the message; mute respected. | MVP-006 | Notification routing tests | done (2026-10-12) |
| MVP-008 | Keyboard completion | Command palette and shortcuts cover navigation, composer focus, send, cancel, sidebar, and search. | MVP-007 | Keyboard-only manual flow | done (2026-10-12) |
| UPD-001 | In-app updates | Zulip Mac checks the repository's GitHub releases at launch (at most every 6 hours) and from a ‘Check for Updates…’ app-menu command and Settings section, and offers the newest release (prereleases included) when it is newer than the installed build. The installed build knows its full release tag (`ZulipReleaseTag`, stamped by packaging). ‘Install and Restart’ downloads the arm64 DMG over HTTPS from GitHub hosts only, verifies its SHA-256 against the release's checksum asset, mounts it read-only, stages the app beside the installed one, verifies the code signature, bundle identifier and tag, then a helper swaps the bundle after the app exits and relaunches it. Failures leave the installed app untouched and are shown in Settings. Unpackaged builds and read-only install locations never attempt an install. | MVP-008 | Swift version ordering, release selection, checksum, trust and controller tests; packaging stamps and verifies the tag; `./scripts/check.sh` | done (2026-10-12) |
| FIX-003 | Wake recovery and diagnostics | Retry the connection immediately when the Mac wakes while the app is offline instead of waiting out a backoff timer; add `os.Logger` breadcrumbs for session lifecycle (retry, resume, core-ended session, wake) without credentials; pin the Rust toolchain in `rust-toolchain.toml` to the version CI uses. | UPD-001 | Swift wake-reconnect test; Rust fmt/clippy/tests under the pinned toolchain; `./scripts/check.sh` | done (2026-10-12) |
| UI-008 | Minimalist system-native visual pass | Replace the custom warm palette with system-derived neutral colors and the user's accent color; let the sidebar use the system translucent material; soften radii; remove chrome that does nothing (dead account chevron, sidebar divider, no-op Reply/Copy link/emoji controls, redundant send hint). Layout, titlebar behavior and keyboard access stay as accepted in `MVP-004B`. | UPD-001 | Existing light/dark shell render tests; `./scripts/check.sh`; fresh packaged-app screenshots reviewed by the owner | done (2026-10-12) |

Milestone exit: two users complete one week of ordinary messaging without the
official client for basic operations.

## Milestone REL — Beta Hardening

| ID | Step | Deliverable and acceptance criteria | Depends on | Verification | Status |
| --- | --- | --- | --- | --- | --- |
| REL-001 | Performance | Batch FFI updates, virtualize long lists, cache parsed content, and keep I/O off the main actor. | MVP-008 | Instruments and large-fixture profile | ready |
| REL-002 | Resilience | Recover or report migration, disk, rate-limit, server-upgrade, and Rust panic failures without corrupting cache. | REL-001 | Failure-injection suite | planned |
| REL-003 | Diagnostics | Redacted structured logs and an explicit user-exported diagnostic bundle. | REL-002 | Secret scanning test | planned |
| REL-004 | Contributor docs | Build guide, architecture, testing, known limits, security policy, and release procedure. | REL-003 | Clean-machine documentation run | planned |
| REL-005 | GitHub beta | Produce arm64 GitHub Release artifacts; pass Cloud and one standard HTTPS self-hosted live smoke; sign/notarize only when Developer ID secrets are configured. | REL-004 | `./scripts/live-smoke.sh` against Cloud and one HTTPS self-hosted server; release smoke checklist | planned |

## Deferred Scope

Browser SSO, simultaneous multi-account sync, administration, offline write
replay, complex formulas/tables, Intel, App Store distribution, and other
platform UIs are explicitly deferred.

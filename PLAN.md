# Zulip Mac Development Plan

Last updated: 2026-07-31

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
| MVP-001 | Browsing | Combined feed, channels, topics, DMs, mentions, starred, unread filters, and history pagination. | CORE-006 | API/reducer/navigation tests | ready |
| MVP-002 | Search | Server-side narrow search and stable navigation to a result message. | MVP-001 | Search fixture and live smoke tests | planned |
| MVP-003 | Message actions | Pending/error/retry states for send, edit, delete, reaction, star, and read operations. | MVP-002 | Mock failure/rollback tests | planned |
| MVP-004 | Files and media | Upload attachments; authenticated, account-isolated media cache; safe local URLs for Swift. | MVP-003 | Upload/cache/security tests | planned |
| MVP-005 | Zulip content | Sanitize server HTML into native `ContentBlock` values with safe unsupported-content fallback. | MVP-004 | Malformed/adversarial HTML corpus | planned |
| MVP-006 | Offline reading and drafts | Cached recent conversations and local drafts work offline; writes require explicit retry after reconnect. | MVP-005 | Offline/relaunch tests | planned |
| MVP-007 | Notifications | Local notifications and badges for DMs/mentions; activation deep-links to the message; mute respected. | MVP-006 | Notification routing tests | planned |
| MVP-008 | Keyboard completion | Command palette and shortcuts cover navigation, composer focus, send, cancel, sidebar, and search. | MVP-007 | Keyboard-only manual flow | planned |

Milestone exit: two users complete one week of ordinary messaging without the
official client for basic operations.

## Milestone REL — Beta Hardening

| ID | Step | Deliverable and acceptance criteria | Depends on | Verification | Status |
| --- | --- | --- | --- | --- | --- |
| REL-001 | Performance | Batch FFI updates, virtualize long lists, cache parsed content, and keep I/O off the main actor. | MVP-008 | Instruments and large-fixture profile | planned |
| REL-002 | Resilience | Recover or report migration, disk, rate-limit, server-upgrade, and Rust panic failures without corrupting cache. | REL-001 | Failure-injection suite | planned |
| REL-003 | Diagnostics | Redacted structured logs and an explicit user-exported diagnostic bundle. | REL-002 | Secret scanning test | planned |
| REL-004 | Contributor docs | Build guide, architecture, testing, known limits, security policy, and release procedure. | REL-003 | Clean-machine documentation run | planned |
| REL-005 | GitHub beta | Produce arm64 GitHub Release artifacts; pass Cloud and one standard HTTPS self-hosted live smoke; sign/notarize only when Developer ID secrets are configured. | REL-004 | `./scripts/live-smoke.sh` against Cloud and one HTTPS self-hosted server; release smoke checklist | planned |

## Deferred Scope

Browser SSO, simultaneous multi-account sync, administration, offline write
replay, complex formulas/tables, Intel, App Store distribution, and other
platform UIs are explicitly deferred.

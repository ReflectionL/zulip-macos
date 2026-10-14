# Zulip Mac Project Guide

This repository contains an independent, native macOS client for Zulip. The
working product name is **Zulip Mac**. It targets macOS 26 and Apple Silicon.

## Start Here

Read these files before changing code:

1. [`AGENTS.md`](AGENTS.md) — project boundaries and mandatory workflow.
2. [`PLAN.md`](PLAN.md) — milestones, step definitions, dependencies, and
   acceptance criteria.
3. [`TRACKER.md`](TRACKER.md) — current step, completed work, verification
   evidence, blockers, and technical debt.

`PLAN.md` is the source of truth for intended work. `TRACKER.md` is the source
of truth for actual progress.

## Current State

The app is in public alpha (latest tag: see the GitHub Releases page). It
supports one account, cached offline reading with local drafts, daily message
actions, quote/forward, @-mention suggestions, DM and mention notifications
with unread counts and a Dock badge, read receipts, presence, in-app updates,
and keyboard navigation (⌘K, ⌘F, ⌘1/⌘2, ⌥⌘↑/↓, ⇧⌘L, ⌘+/−/0). The sidebar offers
only Mentions and Starred (the app opens on Mentions) plus channels and direct
messages. [`README.md`](README.md) lists user-visible features and known
limitations; keep it in sync when a step changes either.

## Architecture

- `app/` — Swift 6 and SwiftUI macOS application. Swift owns presentation,
  window management, keyboard focus, Keychain access, notifications, file
  pickers, and other Apple platform integrations.
- `core/` — Rust workspace. Rust owns Zulip HTTP APIs, authentication sessions,
  event synchronization, domain state, SQLite persistence, message-content
  normalization, and media caching.
- `fixtures/` — deterministic data shared by previews and tests.
- `scripts/` — repeatable local build and verification commands.
- `docs/` — architecture and release documentation that is too detailed for
  this navigation file.
- `.github/workflows/` — `ci.yml` (checks on every pull request and push to
  `main`) and `release.yml` (DMG release).

The intended data flow is:

```text
SwiftUI -> CoreCommand -> Rust actor/API/SQLite
        <- CoreEvent / immutable snapshot <-
```

HTTP response types, database rows, Tokio tasks, and Rust lifetimes must not
cross the FFI boundary. The Swift layer depends on `CoreClientProtocol`; preview
and live implementations must expose the same observable behavior.

## Non-Negotiable Rules

- Never put a password or API key in SQLite, fixtures, source control, crash
  output, or logs. Persistent credentials belong in macOS Keychain.
- Never perform network, database, file, parsing, or blocking FFI work on the
  Swift main actor.
- Do not expose Rust async tasks directly over FFI. Use synchronous command
  submission plus event callbacks/snapshots.
- Keep account-scoped data keyed by `accountId`, even while the UI supports
  only one active account.
- Treat untrusted Zulip HTML as data. Normalize and sanitize it before native
  rendering; never inject it into an unrestricted web view.
- Never mark a message read while the app is in the background, and never
  mark one read merely because a collection (Mentions, Starred, search) was
  opened.
- Preserve existing user changes. Do not rewrite unrelated files or use
  destructive Git commands.

## Mandatory Step Workflow

1. Read `AGENTS.md`, `PLAN.md`, and `TRACKER.md`.
2. Select exactly one `ready` step whose dependencies are complete.
3. In `PLAN.md`, set that step to `in_progress`. In `TRACKER.md`, set it as the
   current step and record its start date.
4. Implement only the agreed scope. If scope, public interfaces, dependencies,
   order, or acceptance criteria must change, update `PLAN.md` before
   continuing.
5. Run every verification command and manual check listed for the step.
6. A step may be closed only after its acceptance criteria pass:
   - set it to `done` with the completion date in `PLAN.md`;
   - record the implementation summary, exact verification evidence, residual
     issues, and commit/PR (when available) in `TRACKER.md`;
   - mark the next unblocked step `ready`.
7. Commit code and the corresponding documentation updates together.

An implementation without the required `PLAN.md` and `TRACKER.md` updates is
not complete. A failing or unverified step remains `in_progress` or `blocked`.
Do not erase completed history from `TRACKER.md`.

Documentation-only changes (for example refreshing this file or `README.md`)
do not need their own step, but must keep `./scripts/check-docs.sh` passing and
must not alter the status of a step that belongs to other work.

## Working Environment

- The pinned Rust toolchain is in `rust-toolchain.toml` and must match the
  version used in both workflows. Run `cargo fmt`, `cargo clippy -- -D warnings`
  and `cargo test --workspace` in `core/` before every push.
- Swift compiles only on macOS 26. Linux or cloud sessions cannot build the
  app, so macOS CI (`./scripts/check.sh` on a `macos-26` runner) is the first
  Swift compile; review Swift changes by hand before pushing.
- Batch related fixes into one branch, one pull request and one CI run. Do not
  start a release build until the owner asks for one.
- Pull requests are merged only after CI is green. The owner has authorized
  merging pull requests opened by the assistant once CI passes.

## Common Commands

These commands become authoritative as their corresponding foundation steps
land:

```bash
./scripts/bootstrap.sh
./scripts/build-core.sh
./scripts/generate-bindings.sh
./scripts/build-app.sh
./scripts/test.sh
./scripts/check.sh
./scripts/package-app.sh release
./scripts/package-dmg.sh release v0.1.0-beta.1
./scripts/live-smoke.sh
./scripts/live-media-smoke-keychain.sh SERVER EMAIL
```

`package-dmg.sh` creates an arm64 DMG and adjacent SHA-256 file under the
ignored `dist/` directory. It verifies the app version, architecture, ad-hoc
signature, and disk image before returning. Alpha packages are not a substitute
for the signed/notarized and self-hosted release gate in `REL-005`.

`live-smoke.sh` reads server URL, email, and password as three stdin lines with
terminal echo disabled. It must print only redacted step results; never pass
credentials as command arguments or environment variables. Run it from a
local interactive terminal; do not inject credentials through an automation
channel unless that channel is known not to mirror stdin.

`live-media-smoke-keychain.sh` reads the existing account API key directly
from macOS Keychain and passes it only to the Rust smoke process over local
stdin. It uploads a tiny image, sends it to the authenticated user, verifies
server rendering plus authenticated cache download, and deletes the disposable
message. Never add credential output or shell tracing to this script.

Until a script exists, use the step-specific commands recorded in `PLAN.md`.

## Releases

Releases are built by `.github/workflows/release.yml` on a `macos-26` runner,
not locally. Start it with a manual workflow dispatch and the version tag as
input (for example `v0.1.0-beta.1`); pushing a `v*` tag also triggers it, but
automation sessions cannot push tags. The workflow runs `./scripts/check.sh`,
packages the DMG with `package-dmg.sh`, and publishes a GitHub release with the
DMG and SHA-256 file; tags containing `-` are prereleases.
The release body is `docs/release-notes/<tag>.md` (two sections:
"修复（Fixes）" and "新功能（New features）", one short, professional line per
change in Chinese followed by its English line, then what still needs the
owner's feedback in both languages) followed by the standard
install note; write that file in the pull request that lands the batch's last
change, or in a small follow-up before dispatching. The in-app updater
reads these releases and compares the stamped `ZulipReleaseTag`, so tags must
increase monotonically.

## Product Boundaries

The first usable release supports one active account, Zulip Cloud and standard
HTTPS self-hosted servers, password/API-key login, cached reading, local
drafts, daily message actions, and DM/mention notifications. The alpha builds
already provide these; remaining beta work is tracked in `PLAN.md` (`REL-*`),
including performance, resilience, diagnostics, and a real self-hosted smoke
test.

Browser SSO, multiple simultaneously synchronized accounts, administration,
offline write replay, complex formula/table rendering, Intel, the Mac App
Store, and non-macOS UIs are intentionally deferred.

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
./scripts/live-smoke.sh
./scripts/live-media-smoke-keychain.sh SERVER EMAIL
```

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

## Product Boundaries

The first usable release supports one active account, Zulip Cloud and standard
HTTPS self-hosted servers, password/API-key login, cached reading, local
drafts, daily message actions, and DM/mention notifications.

Browser SSO, multiple simultaneously synchronized accounts, administration,
offline write replay, complex formula/table rendering, Intel, the Mac App
Store, and non-macOS UIs are intentionally deferred.

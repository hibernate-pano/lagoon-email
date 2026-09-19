# Lagoon

An AI Inbox Operating System for the Apple ecosystem. Current state: **M1.7** — the
mailbox layer is provider-agnostic and **QQ Mail is the primary account** (authorization
code → IMAP sync → read → Briefing Feed → AI summary → SMTP reply → archive/⌘Z undo).
The original Gmail path (OAuth + REST) is preserved and switchable. M1.7 completes the
M1 P0 list: quantified time saved, reply detection, and whitelist auto-archive.

Docs: [M1.5 spec](docs/superpowers/specs/2026-09-11-imap-qq-provider-design.md) ·
[M1.5 plan](docs/superpowers/plans/2026-09-11-imap-qq-provider.md) ·
[M1.5 smoke notes](docs/superpowers/m1-5-smoke.md) ·
[product spec](docs/superpowers/specs/2026-09-09-lagoon-email-design.md) ·
[user guide (zh)](docs/使用说明.md)

## Provider capability matrix

| | QQ Mail (`qq`) | Gmail (`gmail`) |
|---|---|---|
| Connect | in-app form: address + 16-char authorization code, probed against `imap.qq.com:993` before storing | browser OAuth (PKCE) + `GET /api/accounts` polling handshake |
| Sync | IMAP (implicit TLS 993); IDLE when advertised, otherwise UID-window polling; `UIDVALIDITY` change → full resync | Gmail REST (`historyId` cursor) |
| Read body | `FETCH` + MIME → plain text (GBK/GB18030/Shift-JIS aware, HTML stripped) | `format=full` + MIME extractor |
| Classify / summarize | same server pipeline (heuristics + optional LLM) | same |
| Reply (send) | SMTP implicit TLS 465, `MIMEBuilder` output | Gmail `messages.send` with the same `MIMEBuilder` output |
| Archive | `UID MOVE` into the server's archive role folder (creates it if absent; falls back to COPY+EXPUNGE); gated on `capabilities.archiveFolder` | label change |
| Undo | remote move back (`unarchive`) then local flip; sent/unsubscribed/drafted are explicitly not undoable | same |
| Capability discovery | `probe` at connect + `capabilities` refresh in the sync loop | all-true (REST always supports it) |

## What M0 proves

Gmail OAuth (PKCE) → Hummingbird server → Postgres → macOS SwiftUI list.

```
┌──────────────┐  browser OAuth   ┌────────────────┐  SQL (param)  ┌───────────┐
│ macOS client │ ←─────────────── │ Hummingbird    │ ────────────► │ Postgres  │
│ (SwiftUI)    │  GET /api/*      │ + Gmail poller │               │ (Docker)  │
└──────────────┘                  └────────────────┘               └───────────┘
```

## Prerequisites

- macOS 14+, Xcode 26 with Swift 6.3 toolchain
- Docker (OrbStack / Docker Desktop)
- Homebrew `psql` client (optional, scripts fall back to `docker exec`)

## Setup (one time)

```bash
# 1. Start Postgres (mapped to host port 5433 because a local Homebrew
#    postgres typically owns 127.0.0.1:5432)
docker compose up -d

# 2. Copy env template and fill in Gmail OAuth credentials
cp .env.example .env

# 3. Generate the OAuth token encryption key (AES-GCM, 32 random bytes,
#    base64). The server refuses to start without it. Paste the output into
#    .env as LAGOON_TOKEN_KEY=...
openssl rand -base64 32

# 4. Apply migrations (idempotent; tracked in schema_migrations)
bash scripts/db-migrate.sh
```

## Gmail OAuth credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/) → create/select a project.
2. Enable the **Gmail API**.
3. **OAuth consent screen**: External → add yourself as a test user. Add scopes:
   - `https://www.googleapis.com/auth/gmail.readonly`
   - `https://www.googleapis.com/auth/userinfo.email`
   - `openid`
4. **Credentials → Create OAuth client ID → Web application**. Authorized redirect URI:
   ```
   http://127.0.0.1:8080/oauth/gmail/callback
   ```
5. Put the client ID / secret into `.env` as `GMAIL_OAUTH_CLIENT_ID` / `GMAIL_OAUTH_CLIENT_SECRET`.

## Run

```bash
# Terminal 1 — server (loads .env if you use direnv, or export manually)
set -a; source .env; set +a
export DATABASE_URL=postgres://lagoon:lagoon@127.0.0.1:5433/lagoon
swift run LagoonServer

# Terminal 2 — macOS app (LAGOON_SERVER_URL defaults to http://127.0.0.1:8080)
swift run Lagoon

# Optional: build a locally runnable app bundle
bash scripts/build-app.sh
open dist/Lagoon.app

# Optional: keep the local server running after login
bash scripts/install-server-agent.sh
```

The server binds `LAGOON_SERVER_HOST` (default `127.0.0.1`). A non-loopback
value is rejected at startup because M0 has no API authentication. The app
talks to `LAGOON_SERVER_URL` (default `http://127.0.0.1:8080`); set it explicitly
if you changed the host/port:

```bash
LAGOON_SERVER_URL=http://127.0.0.1:8080 swift run Lagoon
```

The connect sheet opens on **QQ Mail**. Enter the address and authorization code;
the server probes IMAP before storing anything. Gmail remains available in the
same sheet: click **Connect Gmail** → approve in browser → return to the app. The app polls
`GET /api/accounts` every ~2 s and switches from the Connect screen to the list
as soon as the account appears (a bare `swift run` executable cannot register a
URL scheme, so the browser cannot call back into the app directly). Your 50 most
recent Gmail messages then appear; the server re-polls every 30 s.

**QQ Mail (primary):** no Google credentials needed — switch the connect screen to
the **QQ Mail** tab, paste the address and a 16-character authorization code
(QQ Mail → Settings → Account → enable IMAP/SMTP → generate code), and the server
probes `imap.qq.com` before storing anything. Details (zh): `docs/使用说明.md` §零.

## Checks

```bash
bash scripts/run-all-tests.sh   # guardrails + self-test + test-DB migrate + swift test + build both
bash scripts/ci-guardrails.sh   # SQL-injection & secrets lint only
bash scripts/test-guardrails.sh # prove the guardrail rules catch fixtures
```

## Repo layout

| Path | Purpose |
|------|---------|
| `Sources/LagoonKit` | Shared types (Account, MessageHeader, MailSyncState, MailCapabilities, SyncHealth), Postgres helpers, SQL migrations |
| `Sources/LagoonServer` | Hummingbird app: OAuth + IMAP/SMTP, provider seam (`MailProvider`), sync engine, poller, API routes |
| `Sources/Lagoon` | macOS SwiftUI app |
| `Sources/LagoonKit/Migrations/*.sql` | Schema, applied by `scripts/db-migrate.sh` |
| `docs/superpowers/` | Specs, implementation plans, smoke notes (`m0-smoke.md`, `m1-5-smoke.md`) |
| `scripts/` | DB migrations, CI guardrails, full check |

## Security posture (spec §6.6) — what is true today

- **All SQL is parameterized** (`$1, $2, …`) — enforced by
  `scripts/ci-guardrails.sh`. The rule scans Swift string literals of any
  length (one-line, multi-line `"""…"""`, raw `#"…\#(x)…"#`, and `+`
  concatenation with any expression) for SQL keywords (case-insensitive) plus
  `\(` / `\#(` interpolation, and is itself proven by
  `scripts/test-guardrails.sh`.
- **No secrets in git** — `.env` is gitignored; `.env.example` ships empty; the
  guardrails scan every tracked file for AWS / GCP / GitHub / OpenAI /
  private-key shaped values and print only redacted matches.
- **Credentials encrypted at rest with AES-GCM**, keyed by `LAGOON_TOKEN_KEY`
  (32 random bytes, base64). The server refuses to start without a valid key.
  This protects Gmail OAuth tokens and QQ authorization codes in `accounts.credentials`
  Postgres. It is **not** end-to-end encryption: the key lives in the server's
  environment next to the database.
- **IMAP/SMTP only 993/465 with implicit TLS and full certificate
  verification** (`NIOSSLStreamTransport`, no “skip verification” switch). Hosts
  come from server-side presets (`imap.qq.com` / `smtp.qq.com`) — never from user
  input, so there is no SSRF surface. QQ authorization codes are sealed into the
  same AES-GCM credentials blob as the Gmail tokens, and never appear in logs,
  error strings or API responses (`GET /api/accounts` returns address, health and
  capabilities only).
- **Server binds loopback only** (`LAGOON_SERVER_HOST`, default `127.0.0.1`); a
  non-loopback host refuses to start. This is a deliberate stopgap because
  **M0 has no API authentication** — anything that can reach the port can read
  synced mail.
- **Message bodies never stored server-side** — M0 stores headers/snippets only;
  body encryption lands in M1.
- **Gmail webhook is stubbed**: `POST /webhook/gmail` returns `501 Not
  Implemented` (it previously returned a misleading `200`); polling is the real
  sync path in M0.
- **Untrusted input validated at boundary** — OAuth ids, Gmail message ids, URL
  params are parsed/bound, never interpolated.

## M0.1 — what changed since the first M0 spike

Fixed:

- **OAuth completion handshake.** `GET /api/accounts` returns a JSON array of
  `{id,provider,email}` (empty array when none). The app polls it and moves from
  Connect to the list within ~2 s. A bare `swift run` executable cannot register
  a URL scheme, so the old “return to the app” step did not actually detect
  completion.
- **Token encryption.** OAuth tokens are AES-GCM encrypted with
  `LAGOON_TOKEN_KEY`; the server refuses to start without a 32-byte base64 key.
- **Token refresh.** The poller refreshes proactively when the access token is
  within 60 s of expiry, and refreshes once + retries once on a `401`. When
  Google omits a new refresh token, the stored one is preserved. Refreshed
  tokens are persisted via `AccountStore.updateTokens`.
- **Loopback enforcement.** `LAGOON_SERVER_HOST` defaults to `127.0.0.1` and a
  non-loopback value refuses to start (no API auth yet).
- **Honest webhook.** `POST /webhook/gmail` returns `501` instead of a fake `200`.
- **Guardrails.** SQL-interpolation rule catches lowercase/mixed-case keywords,
  raw-string `\#(` interpolation, multi-line literals, and bare `+`
  concatenation of a SQL literal with any expression; tracked-file secret scan;
  `.env` rule matches any directory depth; `scripts/test-guardrails.sh` proves
  the rules and runs in CI.
- **Test isolation.** Tests run against a dedicated `lagoon_test` database,
  never the dev database. Cleanup is row-scoped (`DELETE … WHERE id` or
  `WHERE oauth_user`), never a whole-table wipe.

**Upgrade note (breaking).** Token rows written before M0.1 are plaintext and
can no longer be decrypted by the AES-GCM reader. An already-connected account
will silently stop syncing while `GET /api/accounts` still returns it. Remedy:
re-run **Connect Gmail** from the app, or delete the stale `accounts` row.
Rotating `LAGOON_TOKEN_KEY` alone does **not** fix it — the old rows are
unreadable regardless of the key.

## M1 slice — Briefing Feed, full-body reading, AI summary

Shipped in this slice:

- **Briefing Feed is the default landing surface** (spec §7.1). Five groups
  with live counts — 🔴 Needs reply · ⏳ Awaiting their reply · 🟢 Safe to
  archive · 🆕 Subscription noise (collapsed) · 📌 Pinned. ⌘1…⌘5 jump between
  groups; empty groups hide. The raw message list is a secondary surface
  (toolbar picker / ⌘0).
- **Full email body reading.** `GET /api/messages/{gmailId}/body?accountId=…`
  fetches `format=full`, prefers the `text/plain` part and falls back to
  stripped `text/html`. Opening a message marks it read.
- **Real read state.** Gmail's `labelIds` (`UNREAD`) now drives `is_read`; the
  store's conflict update is additive (`is_read OR EXCLUDED.is_read`), so the
  30 s poller can never un-read something you read locally.
- **Pinning.** `message_pins` table + `POST /api/messages/{gmailId}/pin`.
- **AI summary + action items.** `GET /api/messages/{gmailId}/summary` through
  the AI Gateway (`Sources/LagoonAI`, spec §6.5). Returns
  `503 {"error":"ai-not-configured"}` until a provider is configured.
- **AI-assisted classification.** When a provider is configured, the gateway
  overrides the heuristic grouping for the ids it is confident about; a provider
  error falls back to heuristics and never fails the feed.

Classification without an LLM uses deterministic header heuristics
(`Sources/LagoonServer/AI/Heuristics.swift`): pinned → `List-Unsubscribe` or
no-reply sender → sender is you → read and older than 7 days → needs reply.

### Enabling AI

```bash
# .env
LLM_PROVIDER_PRIMARY_API_KEY=<your MiniMax key>
LLM_PROVIDER_PRIMARY_BASE_URL=https://api.minimax.chat/v1   # optional override
LLM_PROVIDER_PRIMARY_MODEL=MiniMax-M3                       # optional override
```

Provider routing and defaults live in `config/providers.json`; see
`Sources/LagoonAI/README.md`. With no key the server stays heuristic-only and
`/summary` returns 503 — it never crashes.

### M1.5 — provider seam, QQ Mail, reply send

- **`MailProvider` seam** (`Sources/LagoonServer/Mail/MailProvider.swift`) with two
  implementations: `GmailProvider` (REST + OAuth) and `IMAPProvider` (IMAP 993 +
  SMTP 465). Routes resolve the provider per account through
  `MailProviderFactory`; tests inject a scripted stub.
- **Migration 008**: `gmail_id` → `remote_id` everywhere, sealed `credentials`
  blob, `sync_state` / `capabilities` / `is_active` / health columns.
- **Migrations 009/010**: send idempotency keys, then stable IMAP identities
  using RFC 5322 `Message-ID` instead of a mailbox-local UID that changes after
  `MOVE`.
- **Sync engine** (`Sources/LagoonServer/Sync/SyncEngine.swift`): one active
  account, IDLE-or-poll pull, `UIDVALIDITY`-change full resync, backoff
  1→2→…→300 s, auth failures stop the loop and surface `needsReconnect`.
- **Reply send**: `POST /api/messages/{remoteId}/send {body,requestId}` → `MIMEBuilder`
  thread-correct message (Re: de-dup, RFC 2047 subjects, base64 body) over SMTP
  (`smtp.qq.com:465`) or Gmail `messages.send`. QQ copies are `APPEND`ed to
  `Sent Messages` because SMTP does not do that automatically. Client sheet
  with ⌘↩; the stable `requestId` prevents a retry after a lost response from
  sending twice.
- **New-message send**: the toolbar's “New message” action posts
  `POST /api/compose/send {to,subject,body,requestId}`. The server validates a
  single RFC-style recipient, keeps the subject unprefixed, sends through the
  same SMTP path and appends the QQ Sent copy.
- **Archive + undo**: provider-side move into the archive folder, gated on
  `capabilities.archiveFolder` (client disables the button, server answers
  409 `archive-unavailable`); ⌘Z reverses locally **and** remotely. Undo
  resolves the stable Message-ID again because QQ assigns a new UID in the
  archive mailbox.
- **Account directory**: `GET /api/accounts` with per-account `syncHealth` +
  `capabilities`; activate/delete; connect UI for both providers.
- **Route provider pool + serialized IMAP commands**: reading mail reuses one
  authenticated QQ connection instead of logging in per message; an async lock
  prevents concurrent UI actions from interleaving tagged IMAP commands.
- **Batched AI classification**: briefing classification runs in small batches
  so large mailboxes cannot truncate the model's JSON at the completion cap.

### Not in this slice

- Multi-draft composer tabs, time-saved status bar, whitelist autonomy,
  SwiftData local cache, Pub/Sub push, Postgres pool, iOS.
- **Real-account QQ verification** — the protocol/logic layer is covered by 373
  automated tests. A real QQ self-test has verified send, receive fallback,
  archive, unarchive and Sent-folder append; the 14-day daily-use soak is still
  recorded manually in
  `docs/superpowers/m1-5-smoke.md`.

### M1.7 — time saved, reply detection, whitelist autopilot

- **Time-saved status bar** (`GET /api/time-saved`): today/week aggregation over the
  `ai_actions` audit log, with undone actions excluded. Minutes are **declared
  estimates** per action kind (`TimeSavedEstimates` in `Sources/LagoonServer/Routes/TimeSavedRoutes.swift`)
  and the UI says so. The bar hides until something has been handled.
- **Reply detection**: a send action recorded by the reply route names the original
  message, and the briefing classifier treats it as handled (`.safeToArchive`, reason
  `replied`) instead of nagging in "needs reply". Replies sent from *other* mail
  clients are invisible — the Sent folder is not synced (below).
- **Whitelist auto-archive** (spec principle #2): right-click a subscription-noise row
  → "Auto-archive this sender" creates an `auto_archive_rules` row and archives the
  message on the spot (both reversible — archive via ⌘Z, rule via ⋮ → Auto-archive
  rules). The sync loop archives matching arrivals the moment they land: remote-first,
  audited with `autoRule`, skipped on `messageGone`, and the round fails (backoff +
  retry) when the provider errors. Rules are offered only on subscription-noise rows,
  so a sender that owes you replies can never be silently blackholed.

## Known limitations (by design)

- No API authentication — the server is loopback-only for that reason
- Reply detection sees only replies sent through Lagoon — mail replied to from
  other clients still shows in "needs reply" until the Sent folder is synced
- **Pre-M0.1 OAuth rows are unreadable, and pre-008 Gmail rows lost their token
  columns** — after migration 008 an existing Gmail account surfaces as
  `sync-failed: not-configured` and stops updating (it still appears in
  `GET /api/accounts`). Reconnect Gmail or delete the stale row.
- Gmail polling every 30 s; `POST /webhook/gmail` returns `501`
- OAuth state stored in-process (lost on server restart)
- No SwiftData local cache — the app refetches from the server
- Gmail `historyId` incremental sync via the API only (no Pub/Sub push)
- Body is fetched on demand and never stored server-side (headers/snippets only)
- Postgres: single connection, no pool
- macOS only; one active account at a time (the directory can hold several)

## Reliability hardening

- Archive and unsubscribe are remote-first. A remote failure returns an error and
  leaves local state unchanged; the old “archived locally only” behavior is gone.
- Every archive response carries the exact `actionId`; the client no longer
  guesses the latest action when showing Undo.
- User classification overrides are applied to subsequent Briefing responses,
  with pins taking precedence.
- Undo enforces the database `expires_at` window and restores remote read/archive
  state before changing the local row.
- AI reply drafting uses a dedicated reply prompt instead of wrapping a summary.
- The monthly budget is wired into the real AI Gateway. If token rates are unset,
  the usage panel explicitly says the dollar cap cannot be enforced.

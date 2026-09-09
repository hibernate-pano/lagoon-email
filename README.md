# Lagoon

An AI Inbox Operating System for the Apple ecosystem. This is the **M0 Spike** — a thin vertical slice proving the Gmail sync architecture end-to-end. No AI features yet; those land in M1.

See `docs/superpowers/specs/2026-09-09-lagoon-email-design.md` for the product spec and `docs/superpowers/plans/2026-09-09-m0-spike.md` for the implementation plan.

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
```

The server binds `LAGOON_SERVER_HOST` (default `127.0.0.1`). A non-loopback
value is rejected at startup because M0 has no API authentication. The app
talks to `LAGOON_SERVER_URL` (default `http://127.0.0.1:8080`); set it explicitly
if you changed the host/port:

```bash
LAGOON_SERVER_URL=http://127.0.0.1:8080 swift run Lagoon
```

Click **Connect Gmail** → approve in browser → return to the app. The app polls
`GET /api/accounts` every ~2 s and switches from the Connect screen to the list
as soon as the account appears (a bare `swift run` executable cannot register a
URL scheme, so the browser cannot call back into the app directly). Your 50 most
recent Gmail messages then appear; the server re-polls every 30 s.

## Checks

```bash
bash scripts/run-all-tests.sh   # guardrails + self-test + test-DB migrate + swift test + build both
bash scripts/ci-guardrails.sh   # SQL-injection & secrets lint only
bash scripts/test-guardrails.sh # prove the guardrail rules catch fixtures
```

## Repo layout

| Path | Purpose |
|------|---------|
| `Sources/LagoonKit` | Shared types (Account, MessageHeader, SyncCursor, SyncResponse), Postgres helpers, SQL migrations |
| `Sources/LagoonServer` | Hummingbird app: OAuth routes, Gmail REST client + 30 s poller, sync API |
| `Sources/Lagoon` | macOS SwiftUI app |
| `Sources/LagoonKit/Migrations/*.sql` | Schema, applied by `scripts/db-migrate.sh` |
| `scripts/` | DB migrations, CI guardrails, full check |

## Security posture (spec §6.6) — what is true in M0.1

- **All SQL is parameterized** (`$1, $2, …`) — enforced by
  `scripts/ci-guardrails.sh`. The rule scans Swift string literals of any
  length (one-line, multi-line `"""…"""`, raw `#"…\#(x)…"#`, and `+`
  concatenation with any expression) for SQL keywords (case-insensitive) plus
  `\(` / `\#(` interpolation, and is itself proven by
  `scripts/test-guardrails.sh`.
- **No secrets in git** — `.env` is gitignored; `.env.example` ships empty; the
  guardrails scan every tracked file for AWS / GCP / GitHub / OpenAI /
  private-key shaped values and print only redacted matches.
- **OAuth tokens encrypted at rest with AES-GCM**, keyed by `LAGOON_TOKEN_KEY`
  (32 random bytes, base64). The server refuses to start without a valid key.
  This protects the `accounts.access_token` / `refresh_token` columns in
  Postgres. It is **not** end-to-end encryption: the key lives in the server's
  environment next to the database.
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

### Not in this slice (still M1)

- Multi-draft composer / send — needs the `gmail.send` + `gmail.compose`
  scopes, which forces re-consent
- Gmail-side archive / label changes — needs `gmail.modify` (archive is
  currently not performed at all; nothing is hidden locally either)
- Undo surface + `ai_actions` table (spec §6.6 rule 7)
- Time-saved status bar, whitelist autonomy, SwiftData local cache, Pub/Sub
  push, Postgres pool, iOS

## Deferred (still M1):

- SwiftData local cache on the client
- Gmail `historyId` incremental sync
- Pub/Sub push + push verification
- API authentication
- Postgres connection pool

## Known limitations (by design, M0.1)

- No API authentication — the server is loopback-only for that reason
- **Pre-M0.1 OAuth rows are unreadable** — plaintext token blobs written before
  AES-GCM cannot be decrypted, so an existing connected account silently stops
  syncing (it still appears in `GET /api/accounts`). Reconnect Gmail or delete
  the stale row; rotating `LAGOON_TOKEN_KEY` alone does not help.
- Gmail polling every 30 s; `POST /webhook/gmail` returns `501` (Pub/Sub push lands in M1)
- OAuth state stored in-process (lost on server restart)
- No SwiftData local cache — the app refetches from the server
- No Gmail `historyId` incremental sync — each poll refetches the 50 most recent messages
- Postgres: single connection, no pool
- macOS only, single Gmail account
- No Briefing Feed / AI — raw list only

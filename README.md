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

# 3. Apply migrations (idempotent; tracked in schema_migrations)
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

# Terminal 2 — macOS app
swift run Lagoon
```

Click **Connect Gmail** → approve in browser → return to the app. Your 50 most
recent Gmail messages appear in the list; the server re-polls every 30 s.

## Checks

```bash
bash scripts/run-all-tests.sh   # guardrails + migrate + swift test + build both
bash scripts/ci-guardrails.sh   # SQL-injection & secrets lint only
```

## Repo layout

| Path | Purpose |
|------|---------|
| `Sources/LagoonKit` | Shared types (Account, MessageHeader, SyncCursor, SyncResponse), Postgres helpers, SQL migrations |
| `Sources/LagoonServer` | Hummingbird app: OAuth routes, Gmail REST client + 30 s poller, sync API |
| `Sources/Lagoon` | macOS SwiftUI app |
| `Sources/LagoonKit/Migrations/*.sql` | Schema, applied by `scripts/db-migrate.sh` |
| `scripts/` | DB migrations, CI guardrails, full check |

## Security posture (spec §6.6)

- **All SQL is parameterized** (`$1, $2, …`) — enforced by `scripts/ci-guardrails.sh`.
- **No secrets in git** — `.env` is gitignored; `.env.example` ships empty.
- **Message bodies never stored server-side** — M0 stores headers/snippets only; body encryption lands in M1.
- **Untrusted input validated at boundary** — OAuth ids, Gmail message ids, URL params are parsed/bound, never interpolated.

## Known limitations (by design, M0)

- Gmail polling every 30 s (Pub/Sub push lands in M1)
- No token refresh (server warns and skips account when the access token expires)
- No Briefing Feed / AI — raw list only
- macOS only, single Gmail account
- OAuth state stored in-process (lost on server restart)

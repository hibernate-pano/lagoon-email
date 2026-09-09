# M0 Smoke Notes

Date: 2026-09-09
Executor: AI co-founder (autonomous), macOS 26 / Xcode 26.6 / Swift 6.3 / OrbStack Docker

> **M0.1 update:** the OAuth completion handshake is now handled by polling
> `GET /api/accounts` (the app switches from Connect to the list within ~2 s
> once the account row exists), so the previous “return to the app” ambiguity is
> gone. The real Google round-trip still needs founder credentials — see
> “NOT verified” below. `POST /webhook/gmail` now returns `501` instead of a
> fake `200`. OAuth tokens are AES-GCM encrypted with a required
> `LAGOON_TOKEN_KEY`, the server refuses a non-loopback `LAGOON_SERVER_HOST`,
> the poller refreshes expired access tokens (proactively ≤60 s before expiry,
> and once + retry once on `401`), and tests run against a dedicated
> `lagoon_test` database.

## Verified end-to-end (automated)

| Check | Result |
|-------|--------|
| `swift build` all three products | ✅ |
| `swift test` | ✅ 60 tests, 0 failures (SQLBuilder, PostgresConfig, Codable roundtrips, AccountStore+MessageStore against real Postgres, AccessTokenCipher, GoogleOAuthClient, OutboundGuard, Route, TestDatabaseGuard, PKCE, FromHeader parsing, Keychain-backed AccountStore, APIClient, MessageListViewModel) |
| `bash scripts/ci-guardrails.sh` | ✅ OK (SQL interpolation lint incl. case-insensitive keywords, raw-string `\#(`, multi-line and bare `+` concat; tracked-file secret scan; tracked-.env check) |
| `bash scripts/test-guardrails.sh` | ✅ 24/24 (fixtures prove the previously-bypassing lowercase/raw-string/bare-concat SQL cases, plus multi-line/concat and secret patterns, are caught) |
| `bash scripts/db-migrate.sh` (idempotent rerun) | ✅ skips applied, applies new |
| Server boot (`swift run LagoonServer`) | ✅ listens on 127.0.0.1:8080 |
| `GET /healthz` | ✅ `ok` |
| `POST /webhook/gmail` | ✅ `501` (was a fake `200`; Pub/Sub lands M1) |
| `GET /api/messages?accountId=<malformed>` | ✅ 400 with message |
| `GET /api/messages?accountId=<valid>` seeded 3 rows | ✅ JSON: 3 messages, `totalUnread: 2`, receivedAt desc, correct From parsing (name/address) |
| Poller loop registered (30 s) | ✅ no errors in log with 0 accounts |
| OAuth start URL redirect construction | ✅ built (unverified against Google — needs credentials) |

## Verified with synthetic data (not Gmail)

Seeded `accounts` + `message_headers` directly, then exercised the API. Proves
DB schema ↔ domain types ↔ JSON contract ↔ client models are consistent.
Synthetic rows removed after the test.

## NOT verified (requires founder action)

1. **Real Gmail OAuth round-trip** — needs Google Cloud OAuth client ID/secret
   (see README "Gmail OAuth credentials"). The flow is now: start server →
   `swift run Lagoon` → click "Connect Gmail" → approve → the app polls
   `GET /api/accounts` and switches to the list once the account appears.
   **The polling handshake itself is implemented but has no automated test yet**, and the full browser round-trip against real Google credentials has not been exercised.
2. **Pub/Sub push** — intentionally stubbed in M0 (polling stands in;
   `POST /webhook/gmail` returns `501`).
3. **Keychain persistence across app relaunches** — unit-tested in code, not
   exercised in a real app launch.
4. **Token encryption against a real Google token** — AES-GCM with
   `LAGOON_TOKEN_KEY` is unit-tested (`AccessTokenCipherTests`: seal/open
   round-trip, ciphertext≠plaintext, tamper, wrong key, missing/malformed key),
   but not exercised with a live Google token. Token refresh is implemented
   (proactive ≤60 s, refresh-once-retry-once on `401`) and covered by unit
   tests, but has not been exercised against real Google.

## Deviations from plan (all documented, none blocking)

| Plan said | Actually done | Why |
|-----------|---------------|-----|
| PostgresNIO 1.20.0 | 1.33.1 | 1.20 does not compile on Swift 6.3 / macOS 26 SDK (`DiscardingTaskGroup` conformance error) |
| `PostgresData(string:…)` direct decoding (`row.column(...).string`) | `PostgresCell.decode(T.self)` via `row.makeRandomAccess()` | 1.33 API: `PostgresRow.column(_:)` is deprecated/O(n), property accessors return Optionals |
| `docker-compose` port 5432 | host port **5433** | Local Homebrew postgres already owns 127.0.0.1:5432 (OrbStack binds *:5432, loopback hits Homebrew) — verified with `lsof -i :5432` |
| `psql` on host | `docker exec … psql` with host fallback | Host psql cannot authenticate as the container-scoped role |
| GoogleSignIn-iOS dependency | dropped | iOS-only package; M0 uses browser OAuth + PKCE (correct for macOS server-driven flow) |
| Migration script plain `psql -f` | `schema_migrations` tracking table | First rerun failed on existing tables; migrations must be idempotent-aware |
| `@main` placeholder executables | Lagoon gets real `@main` in Task 8; LagoonServer got real `@main` in Task 7 | SwiftPM executables need an entry point to link |

## Rough edges to fix in M1

- API auth is missing; the server is loopback-only as a stopgap. Before any
  non-local deployment, add auth and revisit `LAGOON_SERVER_HOST` enforcement.
- Client has no SwiftData local cache; every screen reads from the server.
- Gmail `historyId` incremental sync is missing; each poll refetches the 50 most
  recent messages instead of only changes.
- Pub/Sub push + push verification is not implemented (`/webhook/gmail` = 501).
- Postgres: single connection, no pool. Use a `PostgresClient`/pool + `Sendable` wrapper; route handlers currently capture the non-Sendable connection (warning-free in Swift 5 language mode, will not survive Swift 6 strict concurrency).
- OAuth state is in-memory (lost on restart; broken across multiple server processes).
- Poller polls every account every 30 s with 1 msg/s fetch fan-out; needs historyId incremental sync + backoff.
- `MessageStore.recent` `LIMIT` binds as int param — fine, but count queries for Briefing Feed will need an aggregate endpoint.
- Server binds `127.0.0.1` only — fine for M0, needs public HTTPS for Gmail Pub/Sub in M1.

## Verdict

M0 Spike goal is met on everything that can be verified without Google
credentials. The remaining unknown is the OAuth consent screen UX, which is a
configuration step, not an architecture risk.

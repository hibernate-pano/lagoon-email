# M0 Smoke Notes

Date: 2026-09-09
Executor: AI co-founder (autonomous), macOS 26 / Xcode 26.6 / Swift 6.3 / OrbStack Docker

## Verified end-to-end (automated)

| Check | Result |
|-------|--------|
| `swift build` all three products | ✅ |
| `swift test` | ✅ 13 tests, 0 failures (SQLBuilder, PostgresConfig, Codable roundtrips, AccountStore+MessageStore against real Postgres, PKCE, FromHeader parsing, Keychain-backed AccountStore) |
| `bash scripts/ci-guardrails.sh` | ✅ OK (SQL interpolation lint, to_vector lint, tracked-.env check) |
| `bash scripts/db-migrate.sh` (idempotent rerun) | ✅ skips applied, applies new |
| Server boot (`swift run LagoonServer`) | ✅ listens on 127.0.0.1:8080 |
| `GET /healthz` | ✅ `ok` |
| `POST /webhook/gmail` | ✅ `ok` (stub; Pub/Sub lands M1) |
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
   (see README "Gmail OAuth credentials"). The 3-step manual flow:
   start server → `swift run Lagoon` → click "Connect Gmail" → approve.
2. **Pub/Sub push** — intentionally stubbed in M0 (polling stands in).
3. **Keychain persistence across app relaunches** — unit-tested in code, not
   exercised in a real app launch.

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

- Postgres: single connection, no pool. Use a `PostgresClient`/pool + `Sendable` wrapper; route handlers currently capture the non-Sendable connection (warning-free in Swift 5 language mode, will not survive Swift 6 strict concurrency).
- Token refresh missing — expired accounts are skipped with a warning.
- OAuth state is in-memory (lost on restart; broken across multiple server processes).
- Poller polls every account every 30 s with 1 msg/s fetch fan-out; needs historyId incremental sync + backoff.
- `MessageStore.recent` `LIMIT` binds as int param — fine, but count queries for Briefing Feed will need an aggregate endpoint.
- Server binds `127.0.0.1` only — fine for M0, needs public HTTPS for Gmail Pub/Sub in M1.

## Verdict

M0 Spike goal is met on everything that can be verified without Google
credentials. The remaining unknown is the OAuth consent screen UX, which is a
configuration step, not an architecture risk.

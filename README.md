# Lagoon

An **AI Inbox Operating System for the Apple ecosystem** — currently a
Mac-first, keyboard-first triage machine whose whole promise is one sentence:
*open twice a day, ten minutes to zero; running resident all day = failure*.

Current state: **V3 "embedded"**. The app is self-contained — the Swift
(Hummingbird) server, the sync engine and the storage all run **inside the
`Lagoon.app` process**, on an embedded SQLite store under Application Support.
There is no Docker, no Postgres, no LaunchAgent, no `.env` on a user machine.
Mail lives at the provider; the local store is a cache plus user state
(rules, pins, undo audit), and everything the AI touches is reversible.

```
Lagoon.app（one process）
  ├─ SwiftUI client
  ├─ LagoonRuntime (embedded server, loopback HTTP)
  │     ├─ Sync Engine — one loop per account (IMAP IDLE / polling)
  │     └─ SQLite (WAL, GRDB) — ~/Library/Application Support/Lagoon/
  └─ AI Gateway ──> MiniMax (only AI summary/draft text leaves the machine)
```

Docs: [startup runbook (zh)](docs/启动说明.md) ·
[user guide (zh)](docs/使用说明.md) ·
[v2 final design spec](docs/superpowers/specs/2026-09-23-v2-inbox-os-final-design.md) ·
[original product spec](docs/superpowers/specs/2026-09-09-lagoon-email-design.md)

## Accounts

**QQ Mail is the only supported provider** (authorization code → IMAP sync →
read → Briefing Feed → AI summary → SMTP reply → archive/⌘Z undo). The Gmail
OAuth/REST path was removed for the QQ-only MVP; if it is ever needed again it
returns as a new feature branch, not resurrected code. Multiple mailboxes can
stay connected and sync **concurrently** — each account owns its loop, cursor
and backoff over the shared pool; `is_active` only marks which mailbox the
client shows.

## Provider capability (QQ Mail)

| | QQ Mail (`qq`) |
|---|---|
| Connect | in-app form: address + 16-char authorization code, probed against `imap.qq.com:993` before storing |
| Sync | IMAP (implicit TLS 993); IDLE when advertised, otherwise UID-window polling; `UIDVALIDITY` change → full resync |
| Read body | `FETCH` + MIME → plain text (GBK/GB18030/Shift-JIS aware, HTML stripped) |
| Classify / summarize | same in-process pipeline (heuristics + optional LLM) |
| Reply (send) | SMTP implicit TLS 465, `MIMEBuilder` output |
| Archive | `UID MOVE` into the server's archive role folder (creates it if absent; falls back to COPY+EXPUNGE); gated on `capabilities.archiveFolder` |
| Undo | remote move back (`unarchive`) then local flip; sent/unsubscribed/drafted are explicitly not undoable |

## Storage (V3: embedded SQLite)

One SQLite file (`GRDB`, WAL mode, foreign keys ON) holds everything: accounts
(credential blobs AES-GCM sealed), message headers + bodies, pins, drafts,
`ai_actions` audit log (undo + time-saved), usage/budget log, auto-archive
rules, user-defined stack rules.

- **Schema**: `Sources/LagoonKit/LagoonDatabase.swift` — the final state of
  the historical 19 Postgres migrations, expressed for SQLite as one
  `lagoon-v1` migration applied automatically at startup. Nothing migrates
  from an old Postgres install: remote mail re-syncs from the provider.
- **Concurrency**: one `DatabasePool` shared by every sync loop, route and
  store (`LagoonDB` seam in LagoonKit). The Postgres build needed one
  connection per loop because a wire connection serves one query at a time;
  WAL SQLite has no such constraint. Callers join a caller-owned transaction
  with `LagoonDB(transaction:)` inside `pool.write { … }`.
- **Dates** are TEXT in GRDB's own `yyyy-MM-dd HH:mm:ss.SSS` UTC encoding;
  SQL-side defaults use `strftime('%Y-%m-%d %H:%M:%f','now')`, so Swift-bound
  and SQL-generated values agree lexicographically.
- **JSON columns** (`sync_state`, `payload`, attachments, address arrays) are
  TEXT; payload queries use `json_extract`. The send-idempotency uniqueness
  from Postgres migration 009 lives on as a partial unique index over
  `json_extract(payload, '$.requestId')`.

## Security posture — what is true today

- **All SQL is parameterized** (`?` binds) — enforced by
  `scripts/ci-guardrails.sh`, proven by `scripts/test-guardrails.sh`.
- **No secrets on disk in plaintext**: the AES-GCM key (32 bytes) and the
  per-install API token live in the **Keychain**, generated on first launch.
  The AI provider keys are migrated once from the legacy repo `.env` into the
  Keychain (`lagoon.envJSON`) and never written to a file. The server refuses
  to start without a valid key.
- **Credentials encrypted at rest** with AES-GCM (`AccessTokenCipher`),
  sealing QQ authorization codes in `accounts.credentials`. Not end-to-end encryption: the key is in the
  Keychain of the same machine — that is the trust boundary of a local-first app.
- **IMAP/SMTP only 993/465 with implicit TLS and full certificate
  verification.** Hosts come from server-side presets, never user input.
- **Loopback + Bearer auth**: the embedded server binds `127.0.0.1` and
  every `/api/*` route requires `Authorization: Bearer <token>` with the
  Keychain-held per-install token. The Host-header check (DNS rebinding)
  stays on. A standalone CLI (`LagoonServerCLI`) keeps the env-var contract
  for development and diagnostics (`--self-test`, `--list-mailboxes`,
  `--find-subject`, `--restore`).
- **Message bodies are stored** in the local SQLite store on first open,
  write-through, cascade-deleted with their header row when the provider
  expunges them. Search matches subject/snippet/sender/body with LIKE
  (escaped); the Postgres tsvector arm is gone with the provider.
- **Unsubscribes are SSRF-guarded** (`UnsubscribeScanner`) and archive /
  unsubscribe / delete are remote-first: a remote failure returns an error
  and leaves local state unchanged.

## Build & check

```bash
bash scripts/run-all-tests.sh   # guardrails + self-tests + swift test + build CLI & app
bash scripts/build-app.sh       # dist/Lagoon.app (ad-hoc signed, bundles providers.json)
swift run Lagoon                # app (boots the embedded server first)
swift run LagoonServerCLI       # dev server over the same store, env-var contract
```

Requirements: macOS 14+, Xcode 26 (Swift 6.3 toolchain). Tests are hermetic —
each test opens its own temp-file SQLite store, so `swift test` needs no
Docker and is never skipped.

## AI configuration

```bash
# dev (CLI or `swift run Lagoon`): env contract, unchanged
LLM_PROVIDER_PRIMARY_API_KEY=<your MiniMax key>
LLM_PROVIDER_PRIMARY_BASE_URL=https://api.minimax.chat/v1
LLM_PROVIDER_PRIMARY_MODEL=MiniMax-M3
LAGOON_BUDGET_USD_PER_MONTH=10
```

Provider routing and rates live in `config/providers.json` (bundled into the
app by `scripts/build-app.sh`; the embedded runtime points
`LAGOON_PROVIDER_CONFIG` at the bundled copy). With no key the server stays
heuristic-only and `/summary` returns 503 — it never crashes.

## Historical milestones (condensed)

- **M0–M0.1**: Gmail OAuth → Hummingbird → Postgres → SwiftUI list (the Gmail path was removed in the QQ-only MVP that followed); token
  encryption, loopback enforcement, guardrails.
- **M1**: Briefing Feed as the default surface, full-body reading, real read
  state, pinning, AI summary + classification, undo with exact actionId.
- **M1.5**: provider seam (`MailProvider`), QQ Mail, reply send, sync engine,
  batched AI classification.
- **M1.7**: time-saved status bar, cross-client reply detection, whitelist
  auto-archive.
- **M1.8 → V2**: concurrent multi-account sync, Sent-folder reply signals,
  bodies + FTS server-side, per-install API token, one-click unsubscribe,
  conversation/sender grouping lenses, user-defined stacks, archive cabinet,
  trash delete, sweep, rule suggestions (v2.2.0).
- **V3 (this)**: embedded runtime — SQLite replaces Docker Postgres, the
  server becomes a library inside the app, secrets move to the Keychain.

## Known limitations (by design)

- Distribution still needs Developer ID signing + notarization; the current
  bundle is ad-hoc signed for local use.
- No SwiftData client mirror; the client refetches from the embedded server.
- Search is LIKE-based (no FTS5/trigram yet); CJK substring recall is exact,
  English inflection recall is gone with the tsvector arm.
- OAuth state is in-process (lost on restart).
- macOS only. Attachments >25MB, S/MIME/PGP and multi-draft tabs remain
  non-goals (spec §4: debt, not features).

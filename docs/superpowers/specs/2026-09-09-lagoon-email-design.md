# Lagoon · Product & Engineering Design

**Date:** 2026-09-09
**Status:** Draft for review
**Audience:** Solo founder + AI co-founder
**Stage:** Pre-M0 Spike

---

## 1. Vision

Lagoon is an **AI Inbox Operating System** for the Apple ecosystem. The app opens to an AI-curated Briefing Feed — not a raw message list. Every AI action is reversible; routine categories can run unattended under an explicit whitelist. The human is always the final reviewer; the AI is always the inbox operator.

---

## 2. Product Principles

| # | Principle | Concrete expression in Lagoon |
|---|-----------|-------------------------------|
| 1 | AI Inbox leads, human reviews | Briefing Feed is the default landing surface. The raw conversation list is a secondary view opened from a card. |
| 2 | Assistant by default, autopilot by whitelist | Every AI action has Undo. User opts a category into fully-autonomous mode (e.g. "marketing mail"). |
| 3 | Quantified time saved | A persistent status bar shows minutes saved, messages handled, drafts sent, today and week-to-date. |
| 4 | Minimal, single-glance | No button exists that the user has not invoked. Sections hide when empty. |
| 5 | Water-smooth interaction | 60/120Hz animations, gesture-first, keyboard-first on macOS. Native SwiftUI spring animations throughout. |
| 6 | Closed-loop automation | From "email arrives" to "AI finished" is one tap where allowed, never more than three taps where confirmation is required. |

---

## 3. Core Experience Loop (10 seconds)

1. **Open app → Briefing Feed.** Five card groups, all derived live:
   - 🔴 Needs reply (3)
   - ⏳ Awaiting their reply (5)
   - 🟢 Safe to archive (47, one-tap bulk action)
   - 🆕 Subscription noise (120, collapsed by default; 3s gesture to resurrect)
   - 📌 Pinned (manual)
2. **Tap "Needs reply" card → AI produces 3 drafts** → Tab key cycles through tones (formal / concise / different angle) → ⌘↩ sends.
3. **Long-press / right-click any card → "Why?"** → AI explains its grouping or suggestion. One-tap Undo of all AI actions in the last 30 days.
4. **Status bar pulse:** "Today Lagoon saved you 47 minutes and handled 132 messages."

---

## 4. Platform Scope

| Platform | Role | Phase |
|----------|------|-------|
| **macOS** | Heavy lifter: AI inference routing, local embedding index, sync engine, primary writing surface | M1 |
| **iOS / iPadOS** | Read + reply companion; shares CloudKit state; receives APNs push | M2 |
| **watchOS** | Glance summary of today's Briefing counts; quick mark-as-handled | M3 (post-distribution) |
| **visionOS** | Spatial Briefing overlay | Out of scope for v1 |

**Not built:** Web client, Android client. Depth over breadth.

---

## 5. AI Capabilities

### P0 — must ship in M1

| Capability | Default execution mode | Undo |
|------------|------------------------|------|
| Smart bundling (cluster by sender / subject / project) | Background, always on | n/a (read-only) |
| AI summary + action-item extraction per conversation | Automatic; action items push to Reminders via EventKit | One-tap dismiss |
| Multi-draft composer with Tab switcher | Human confirms before send | Edit before send |
| Auto-archive / delete / label with whitelist | Assistant mode by default; whitelist categories go autonomous | Full Undo, 30-day window |

### P1 — M2 / M3

- AI auto-reply based on historical voice + relationship graph (whitelist only)
- Cross-mailbox workflows ("process all Amazon logistics updates")
- Briefing ↔ Detail mode toggle per session
- "Ask Lagoon" natural-language inbox search

### P2 — post-distribution

- Email → Calendar event suggestion
- Email → Reminders task (beyond action-item extraction)
- Shared team templates (multi-user only)
- Multi-account per provider

---

## 6. Technical Architecture

### 6.1 Stack

| Layer | Choice |
|-------|--------|
| Client | Swift 5.10+, SwiftUI (iOS/macOS), AppKit fallback where SwiftUI falls short |
| Local storage | SwiftData + sqlite-vec for vector search |
| Local embedding | Apple NaturalLanguage + bge-small-en-v1.5 (quantized, on-device) |
| Server | Swift backend — **Hummingbird** (preferred over Vapor: leaner, async-first, better fit for our concurrency model). Decision revisit at M2 if pain emerges. |
| Database | Postgres + pgvector. **Local dev:** Postgres.app or Docker `postgres:16 + pgvector/pgvector:pg16`, configured via `DATABASE_URL` in `.env`. **Production:** Fly.io managed Postgres (same region as the Swift backend Pods; 6PN internal address). Switching is a single env var; application code is identical. |
| Cache / queue | Redis |
| Object storage | Cloudflare R2 (attachments) |
| LLM provider | **MiniMax-M3** (MiniMax 国内版本) primary. Provider abstraction in §6.5 allows swapping/adding models without code changes elsewhere. |
| Push | APNs (iOS/macOS) |
| Hosting | Fly.io for the Swift backend; Cloudflare for static / edge |
| E2E encryption | libsodium sealed boxes between client and server for message body transport |

### 6.2 Module boundaries

```
┌────────────────────────────────────────────────────────┐
│  Client (macOS / iOS)                                  │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────────┐  │
│  │ SwiftUI UI │ │ Local Cache │ │ Local Embedding │  │
│  │             │ │ (SwiftData) │ │ (bge-small)     │  │
│  └─────────────┘ └─────────────┘ └─────────────────┘  │
│         ▲                                             │
└─────────┼──────────────────────────────────────────────┘
          │ HTTPS / WSS (E2E encrypted)
          ▼
┌────────────────────────────────────────────────────────┐
│  Server (Hummingbird)                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐  │
│  │ Gmail    │ │ IMAP     │ │ AI       │ │ Sync     │  │
│  │ Push     │ │ Sync     │ │ Gateway  │ │ Engine   │  │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘  │
└────────────────────────────────────────────────────────┘
          │                          │
          ▼                          ▼
   ┌─────────────┐            ┌──────────────┐
   │ LLM Providers│           │ Postgres +   │
   │ (MiniMax-M3,│            │ pgvector     │
   │  see §6.5)  │            │              │
   └─────────────┘            └──────────────┘
```

**Hard boundaries:**

- `AI Gateway` is the only module that talks to LLM providers (see §6.5). It receives tasks, not raw messages.
- `Sync Engine` never calls AI directly. It emits events; the AI Gateway consumes them.
- `Local Embedding` runs only on the client. The server never sees message bodies, only vectors + metadata.

### 6.3 Data model (initial)

| Table | Purpose |
|-------|---------|
| `accounts` | One row per connected mailbox; provider, OAuth tokens (encrypted at rest), capabilities |
| `messages` | Server stores metadata only (id, thread_id, headers, embedding_vector). Bodies live encrypted on client + S3-compatible store. |
| `threads` | Server-stored groupings; `bundle_reason` field explains why AI clustered them |
| `bundles` | UI-level grouping; superset of threads |
| `ai_actions` | Every action Lagoon takes; `undo_token`, `expires_at`, `reversible_until` |
| `whitelists` | Categories where AI runs unattended (e.g. "marketing", "newsletters") |
| `time_saved_log` | Per-action estimate; aggregated daily/weekly |

### 6.4 Sync strategy

- **Gmail API first.** Pub/Sub push notifications route to Hummingbird endpoint, which fans out to interested client sessions over WSS.
- **IMAP fallback.** IDLE where supported, polling (60s adaptive) otherwise. No real-time push for IMAP in v1.
- **Conflict resolution.** Server is source of truth for metadata; client is source of truth for read-state UI affordances; last-writer-wins for flags with millisecond timestamps.

### 6.5 LLM Provider Registry

The AI Gateway never imports a vendor SDK directly. It talks to providers through a `LLMProvider` protocol. Adding or swapping a model is a config change, not a code change elsewhere.

**Active providers (initial):**

| Priority | Provider | Model | Role |
|----------|----------|-------|------|
| 1 (default) | MiniMax | **MiniMax-M3** (国内版本) | All tasks (summary, bundle, draft, classify, action-item) |
| 2 (fallback) | _TBD_ | _TBD_ | Activated if MiniMax-M3 errors > N times in a window or quota exceeded |

**Adding new providers** (future, founder-driven):

1. Implement `LLMProvider` protocol (single Swift file under `Sources/LagoonAI/Providers/`).
2. Register in `config/providers.json` with name, base URL, API key env var, model id, cost per 1k tokens.
3. Add to provider priority list in the same config.
4. No call-site changes; the Gateway routes by capability tag (`summary`, `draft`, `classify`).

**Per-task routing** (configured in `config/providers.json`, not hardcoded):

| Capability | Default model | Fallback |
|------------|---------------|----------|
| `summary` | MiniMax-M3 | next provider |
| `draft` | MiniMax-M3 | next provider |
| `classify` | MiniMax-M3 | next provider |
| `action_item` | MiniMax-M3 | next provider |
| `bundle_reason` | MiniMax-M3 | next provider |

**Cost & quota guardrails:**

- Per-account monthly budget cap (USD). Hard fail above cap; soft warn at 80%.
- Per-provider circuit breaker: open after 5 consecutive 5xx in 60s; half-open probe after 5 min.
- All provider calls logged with: capability, model, prompt tokens, completion tokens, latency, cost estimate, success/error.

**Data residency:**

- MiniMax 国内版本 implies data stays within MiniMax's domestic infrastructure. Provider selection respects this — no fallback to overseas providers for Chinese-account users (configurable per account in v1.1).

### 6.6 Security & Engineering Conventions

These rules apply to **all code in this repo** and are checked at code review time. They are non-negotiable.

| # | Rule | Enforcement |
|---|------|-------------|
| 1 | **All SQL queries use parameter binding.** No string concatenation, no f-strings, no `format()` to assemble SQL — anywhere. This applies to migrations, ad-hoc scripts, and tests, not just request paths. | Code review + CI grep guard (`rg` patterns for `format(`, f-string `SELECT/INSERT/UPDATE/DELETE`, raw template SQL fragments) must return zero hits outside `SQLBuilder.swift`. |
| 2 | All external input treated as untrusted. OAuth user id, Gmail message id, IMAP UID, URL path components, search queries — every value crossing the trust boundary is bound as a parameter, never interpolated. | Code review; type system encodes `Raw` vs `Validated` at boundary. |
| 3 | pgvector queries: `embedding <=> $1::vector` with the vector passed as a string parameter; do **not** call `to_vector()` on server-side concatenated strings. | Code review. |
| 4 | No secrets in code or git history. OAuth client secrets, LLM API keys, Fly deploy tokens live in Fly Secrets / macOS Keychain. `.env` files are `.gitignore`d and never committed. `.env.example` ships with empty values only. | `git-secrets` + pre-commit hook + CI scan. |
| 5 | Message bodies never leave the client unencrypted. Server stores ciphertext + metadata only. Body encryption keys live in client keychain (Keychain on Apple platforms). | Architectural review; unit test that asserts no plaintext body field exists in any server-side table. |
| 6 | LLM calls go through `LLMProvider`. No file imports a vendor SDK directly except the provider implementation itself. | CI grep: vendor SDK imports outside `Sources/LagoonAI/Providers/` must be empty. |
| 7 | Every AI action is reversible for ≥ 30 days. The `ai_actions` table stores the full action + its inverse, with `reversible_until = created_at + 30d`. Code that deletes from `ai_actions` must check the retention window. | DB constraint + unit test. |
| 8 | All timestamps in UTC at the storage layer. Localized only at the UI edge. | Code review. |
| 9 | All money / quota values are integer cents or integer micro-USD; never floats. | Type system (`Money` newtype) + code review. |
| 10 | Dependencies pinned in `Package.swift` with exact versions for v1; semver ranges only with explicit founder approval. | Code review. |

**CI guardrails** (to be wired in M0 once the project skeleton exists):

- `rg` checks for SQL-injection patterns (rule 1, 3)
- `rg` checks for direct vendor SDK imports outside `Providers/` (rule 6)
- `swift run lagoon-lint-secrets` — fails if `.env` is tracked or any file matches known API key prefixes

---

## 7. UX Direction

### 7.1 Briefing Feed (default landing)

- Five vertical card groups. Counts are live.
- Each card reveals on tap; transitions to a Detail mode that shows the underlying thread(s) with AI summary at top.
- Cmd-1..Cmd-5 keyboard shortcuts jump between groups on macOS.

### 7.2 Composer

- Tap "Reply" → AI drafts three versions.
- Tab cycles drafts. Shift-Tab cycles backward.
- Cmd-; opens a tone-shift menu (more formal / shorter / different angle / ask me).
- ⌘↩ sends. Esc cancels and discards draft.

### 7.3 Undo surface

- Global Undo button in toolbar shows last action + remaining TTL.
- Cmd-Z undoes the last action.
- A "What did Lagoon do?" page lists every AI action in the last 30 days, one-click revert each.

### 7.4 Visual language

- Native macOS Sonoma / iOS 18 design tokens.
- No custom colors that fight system appearance.
- Spring animations: response 0.35s, dampingFraction 0.85.
- Typography: SF Pro, dynamic type honored.

---

## 8. Milestones

| Milestone | Duration | Deliverable |
|-----------|----------|-------------|
| **M0 · Spike** | 2 weeks | Gmail OAuth + Pub/Sub push → server → local SwiftData cache → trivial SwiftUI list. Prove end-to-end sync. |
| **M1 · Self-use MVP** | 6 weeks | Briefing Feed + summary + bundling + draft v1 + Undo (Gmail API + macOS only). |
| **M2 · Self-use mature** | 6 weeks | + iOS client + IMAP/SMTP provider + archive whitelist + time-saved dashboard. |
| **M3 · Distributable** | 8 weeks | + multi-account + settings hierarchy + privacy whitepaper + Mac App Store submission. |
| **M4 · Growth** | TBD | Subscription system + landing site + invite flow. |

Each milestone ends with a self-use soak of ≥ 14 days before the next one starts. If a milestone does not improve daily email handling for the founder, it has failed regardless of feature completeness.

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Gmail API quota / rate limits | Per-account token pool; batch fetches; exponential backoff with jitter |
| AI hallucinations / mis-archives | 100% reversible actions; mandatory "Why?" explanation on every suggestion; whitelist for autonomy |
| LLM cost explosion | Local embedding for retrieval; task router routes small jobs to small models; monthly budget alert at 80% |
| SwiftUI smoothness ceiling | Profile early; fall back to AppKit for hot paths (scrolling lists, gesture recognizers); ProMotion priority |
| Solo founder burnout | Strict P1+ deferral; every milestone must justify itself by daily-use improvement |
| Vendor lock-in (LLM) | Provider abstraction in §6.5; `config/providers.json` controls routing; cross-check for high-stakes actions is a v1.1 addition |
| Privacy incident | Bodies never leave client unencrypted; pgvector never holds raw text; incident response runbook from M3 |

---

## 10. Out of Scope (v1)

- Team / shared inbox
- Calendar / Contacts integration beyond Reminders
- Browser extension
- Web client
- Custom themes / skins
- Plugins / extension API

These are listed so they do not quietly creep into M1.

---

## 11. Open Questions (resolved at brainstorm)

| Question | Resolution |
|----------|------------|
| Product name | **Lagoon** |
| Backend language | **Swift (Hummingbird)** |
| LLM provider | **MiniMax-M3** primary (MiniMax 国内版本); additional providers added later via §6.5 abstraction |
| M0 provider priority | **Gmail API first**, IMAP as fallback |
| iOS timing | **macOS-only for M1**; iOS joins at M2 |
| Local LLM in v1 | **No** — cloud LLM + on-device embedding only; revisit at M3 if cost/privacy pressure mounts |
| Business model | **Deferred** |

---

## 12. Definition of Done (for the design itself)

This design is "done enough to start M0" when:

- [ ] Founder has read this spec end-to-end
- [ ] Founder has flagged any contradictions or missing decisions
- [ ] An implementation plan exists (produced via writing-plans skill)
- [ ] M0 Spike scope is unambiguous: Gmail OAuth + Pub/Sub → Hummingbird → local cache → trivial SwiftUI list
-- M1.7 whitelist autopilot (spec 2026-09-19 §3): senders whose mail is
-- archived automatically the moment it lands. Exact sender address, unique
-- per account — the same granularity the classification overrides use.

CREATE TABLE IF NOT EXISTS auto_archive_rules (
    id             BIGSERIAL PRIMARY KEY,
    account_id     UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    sender_address TEXT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (account_id, sender_address)
);

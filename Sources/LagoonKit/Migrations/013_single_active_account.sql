-- M1.8 final: the server syncs exactly one account at a time.
--
-- Migration 012 renamed `is_active` to `sync_enabled` and marked every row
-- true, which made all mailboxes sync in parallel. The product contract is
-- narrower: every account stays connected, but only the active one owns a
-- provider connection and receives mail. Dormant mailboxes keep their local
-- data and cursors and catch up when selected.
--
-- 012 is retained because local/test databases may already have applied it.
-- This migration restores the single-active invariant on top of that history.
ALTER TABLE accounts ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT FALSE;

-- Deterministically preserve one mailbox across the transition. If there are
-- no accounts yet, the UPDATE is a no-op and the first connect selects one.
WITH newest AS (
    SELECT id
    FROM accounts
    ORDER BY updated_at DESC, id
    LIMIT 1
)
UPDATE accounts
SET is_active = TRUE
WHERE id IN (SELECT id FROM newest);

-- Enforce "at most one active account" in the schema. AccountStore.setActive
-- clears the old row before setting the new one inside a transaction.
CREATE UNIQUE INDEX accounts_one_active
    ON accounts (is_active)
    WHERE is_active;

ALTER TABLE accounts DROP COLUMN sync_enabled;

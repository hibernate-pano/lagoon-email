-- M1.8: every account syncs; "which account am I looking at" becomes a
-- client-local preference instead of a server flag.
--
-- Before this migration `is_active` carried two meanings at once — the sync
-- engine's "the one account to poll" and the client's "the one account to
-- show" — which made two connected mailboxes mutually exclusive: switching to
-- one stopped the other's sync entirely (no poll, no IDLE, frozen
-- last_sync_at). `setActive` enforced it (`is_active = (id = $1)`).
--
-- Non-destructive: the column is only renamed, and every existing row is
-- marked syncable. No data is dropped. `RENAME COLUMN` preserves NOT NULL and
-- the DEFAULT.
ALTER TABLE accounts RENAME COLUMN is_active TO sync_enabled;

-- Any account connected before this milestone was already either the single
-- syncing one or a dormant one; from here on all of them sync in parallel
-- under their own loop.
UPDATE accounts SET sync_enabled = TRUE;

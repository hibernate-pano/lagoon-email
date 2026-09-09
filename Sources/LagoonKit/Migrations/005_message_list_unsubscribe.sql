-- M1: remember whether a message carried a List-Unsubscribe header. The
-- heuristic briefing classifier uses it to group subscription noise without a
-- per-message Gmail round-trip. Additive on re-sync (once TRUE, stays TRUE).
ALTER TABLE message_headers
    ADD COLUMN IF NOT EXISTS list_unsubscribe BOOLEAN NOT NULL DEFAULT FALSE;

-- V2 A3: message bodies are durable server-side state, not a 60s memory.
--
-- Write-through store populated on first open (no mass backfill: fetching
-- every historic body from QQ on upgrade would be a thundering herd, and
-- bodies are immutable so lazy fill converges on its own). The foreign key
-- into message_headers keeps bodies consistent with reconciliation: an
-- expunged header row takes its body with it, so a stored body can never
-- serve content for a message the server no longer knows.
--
-- The GIN index is real FTS for the search route (`plainto_tsquery` over
-- `simple` — never throws on user input; CJK recall comes from the ILIKE
-- side of the OR, English inflection recall from the tsvector side).
CREATE TABLE IF NOT EXISTS message_bodies (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    remote_id  TEXT NOT NULL,
    body_text  TEXT NOT NULL DEFAULT '',
    body_html  TEXT,
    has_more   BOOLEAN NOT NULL DEFAULT FALSE,
    attachments JSONB NOT NULL DEFAULT '[]'::jsonb,
    fetched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, remote_id),
    FOREIGN KEY (account_id, remote_id)
        REFERENCES message_headers(account_id, remote_id)
        ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS message_bodies_fts_idx
    ON message_bodies USING gin (to_tsvector('simple', body_text));

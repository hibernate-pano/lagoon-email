-- M2+: the audit log that powers undo + the per-message override signal.

CREATE TABLE IF NOT EXISTS ai_actions (
    id BIGSERIAL PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 days')
);
CREATE INDEX IF NOT EXISTS ai_actions_account_created_idx
    ON ai_actions(account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ai_actions_expires_idx
    ON ai_actions(expires_at);

-- AI-generated reply drafts. `chosen_variant` is null until the user picks one.
CREATE TABLE IF NOT EXISTS draft_replies (
    id BIGSERIAL PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    gmail_id TEXT NOT NULL,
    variants JSONB NOT NULL,
    chosen_variant INT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS draft_replies_gmail_id_idx
    ON draft_replies(gmail_id, created_at DESC);

-- User overrides on AI classification. The heuristic applies these to push
-- future calls to the group the user actually wanted.
CREATE TABLE IF NOT EXISTS ai_overrides (
    id BIGSERIAL PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    gmail_id TEXT NOT NULL,
    from_group TEXT NOT NULL,
    to_group TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ai_overrides_gmail_id_idx
    ON ai_overrides(gmail_id);

-- Searchable cache of every message Lagoon has ever seen. Cheap search.
CREATE INDEX IF NOT EXISTS message_headers_search_idx
    ON message_headers USING gin (
        to_tsvector('simple',
            coalesce(subject, '') || ' ' || coalesce(snippet, '') || ' ' ||
            coalesce(from_name, '') || ' ' || from_address
        )
    );
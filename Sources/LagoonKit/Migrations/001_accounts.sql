CREATE TABLE IF NOT EXISTS accounts (
    id           UUID PRIMARY KEY,
    provider     TEXT NOT NULL CHECK (provider IN ('gmail')),
    oauth_user   TEXT NOT NULL,
    email        TEXT NOT NULL,
    access_token BYTEA NOT NULL,    -- AES-GCM at rest, keyed by LAGOON_TOKEN_KEY (server-side)
    refresh_token BYTEA NOT NULL,
    token_expires_at TIMESTAMPTZ NOT NULL,
    history_id   TEXT,               -- Gmail historyId for incremental sync
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider, oauth_user)
);
CREATE INDEX IF NOT EXISTS accounts_provider_idx ON accounts (provider);
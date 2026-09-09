CREATE TABLE accounts (
    id           UUID PRIMARY KEY,
    provider     TEXT NOT NULL CHECK (provider IN ('gmail')),
    oauth_user   TEXT NOT NULL,
    email        TEXT NOT NULL,
    access_token BYTEA NOT NULL,    -- encrypted at rest; key in client keychain
    refresh_token BYTEA NOT NULL,
    token_expires_at TIMESTAMPTZ NOT NULL,
    history_id   TEXT,               -- Gmail historyId for incremental sync
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider, oauth_user)
);
CREATE INDEX accounts_provider_idx ON accounts (provider);
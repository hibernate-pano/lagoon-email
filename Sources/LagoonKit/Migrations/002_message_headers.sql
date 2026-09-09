CREATE TABLE message_headers (
    id            UUID PRIMARY KEY,
    account_id    UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    gmail_id      TEXT NOT NULL,
    thread_id     TEXT NOT NULL,
    from_address  TEXT NOT NULL,
    from_name     TEXT,
    subject       TEXT,
    snippet       TEXT,
    received_at   TIMESTAMPTZ NOT NULL,
    is_read       BOOLEAN NOT NULL DEFAULT FALSE,
    is_archived   BOOLEAN NOT NULL DEFAULT FALSE,
    fetched_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (account_id, gmail_id)
);
CREATE INDEX message_headers_account_received_idx
    ON message_headers (account_id, received_at DESC);
CREATE INDEX message_headers_thread_idx
    ON message_headers (account_id, thread_id);
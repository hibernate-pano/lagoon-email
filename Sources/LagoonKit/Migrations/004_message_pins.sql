-- M1: local message pins. Pins are user state that must survive re-sync, so
-- they live in their own table rather than a column on message_headers.
CREATE TABLE IF NOT EXISTS message_pins (
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    gmail_id   TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, gmail_id)
);

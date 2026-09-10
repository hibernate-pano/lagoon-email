-- M1: per-account monthly token usage, the source of truth for the
-- §6.5 budget cap. Append-only: every LLM call inserts a row.
CREATE TABLE IF NOT EXISTS usage_log (
    id BIGSERIAL PRIMARY KEY,
    year_month TEXT NOT NULL,
    account_email TEXT NOT NULL,
    capability TEXT NOT NULL,
    model TEXT NOT NULL,
    prompt_tokens BIGINT NOT NULL,
    completion_tokens BIGINT NOT NULL,
    cost_micro_usd BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS usage_log_year_month_idx ON usage_log(year_month);
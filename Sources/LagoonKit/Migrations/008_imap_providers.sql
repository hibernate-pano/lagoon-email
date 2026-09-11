-- M1.5: 从 Gmail 专用身份/凭据泛化到多 provider（QQ/IMAP）。
-- 破坏性：旧 token 列被删除——密文无法在 SQL 内重密封（解密+重封需要 LAGOON_TOKEN_KEY）。
-- 迁移前请先 pg_dump；既有 Gmail 账号会显示 needsReconnect，重新 Connect 一次即可恢复。

ALTER TABLE accounts DROP CONSTRAINT IF EXISTS accounts_provider_check;
ALTER TABLE accounts ADD CONSTRAINT accounts_provider_check CHECK (provider IN ('gmail','qq'));

ALTER TABLE accounts
    ADD COLUMN IF NOT EXISTS credentials    BYTEA,
    ADD COLUMN IF NOT EXISTS sync_state     JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS capabilities   JSONB NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS sync_status    TEXT NOT NULL DEFAULT 'ok',
    ADD COLUMN IF NOT EXISTS last_sync_at   TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_sync_error TEXT;

UPDATE accounts SET sync_state = jsonb_build_object('historyId', history_id)
 WHERE history_id IS NOT NULL AND sync_state = '{}'::jsonb;

ALTER TABLE message_headers RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE message_pins    RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE draft_replies   RENAME COLUMN gmail_id TO remote_id;
ALTER TABLE ai_overrides    RENAME COLUMN gmail_id TO remote_id;
ALTER INDEX IF EXISTS draft_replies_gmail_id_idx RENAME TO draft_replies_remote_id_idx;
ALTER INDEX IF EXISTS ai_overrides_gmail_id_idx  RENAME TO ai_overrides_remote_id_idx;

ALTER TABLE message_headers
    ADD COLUMN IF NOT EXISTS message_id_header TEXT,
    ADD COLUMN IF NOT EXISTS in_reply_to       TEXT,
    ADD COLUMN IF NOT EXISTS references_header TEXT;

UPDATE ai_actions
   SET payload = (payload - 'gmailId') || jsonb_build_object('remoteId', payload->'gmailId')
 WHERE payload ? 'gmailId';

ALTER TABLE accounts
    DROP COLUMN IF EXISTS access_token,
    DROP COLUMN IF EXISTS refresh_token,
    DROP COLUMN IF EXISTS token_expires_at,
    DROP COLUMN IF EXISTS history_id;

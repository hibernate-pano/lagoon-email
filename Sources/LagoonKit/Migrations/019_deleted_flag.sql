-- 删除 = 移入服务器废纸篓后的本地标记。与 is_archived 分开：档案柜（已归档）
-- 保留可检索性，废纸篓不进搜索、不进未读数、不进任何列表。服务器端邮件本体
-- 仍在 Trash 文件夹里，撤销（restore）即移回 INBOX。
ALTER TABLE message_headers
    ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN NOT NULL DEFAULT FALSE;
CREATE INDEX IF NOT EXISTS message_headers_account_deleted_idx
    ON message_headers (account_id, received_at DESC) WHERE is_deleted = FALSE;

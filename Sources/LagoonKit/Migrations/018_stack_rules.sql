-- 用户自定义聚合（归集规则）— HEY Stack / Outlook Search Folder 的等价物。
-- 一条规则 = 一个命名聚合：kind=sender 精确匹配 from_address；kind=keyword
-- 对 subject 做大小写不敏感的包含匹配（SQL ILIKE，值经 ESCAPE 转义后绑定）。
-- 命中求值在读取时进行：未来的邮件自动归入，无需逐封登记。
CREATE TABLE IF NOT EXISTS stack_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('sender', 'keyword')),
    value TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS stack_rules_account_idx ON stack_rules (account_id);

# ADR 0002 · R1 通过：Rust 后端与 v3 逐字段对齐，后端迁移从「M3」提前

- 日期：2026-10-29
- 状态：**已采纳**（用户要求「Rust + Web」，因此 Rust 后端不再等 M3）
- 背景：`00-理解与方案.md` 原本把后端迁移排在 M3；用户明确「我说是 rust + web」，所以顺序改为：先把 Rust 后端的只读面铺满，再让外壳从「Swift 边车」切到「Rust 后端」，最后由 Rust 实现写路径与同步。

## 决定

1. **R1 只读切片已通过**（`crates/lagoon-api`）：26 单测 + 18 golden fixtures + 7 只读路径 + 1 真 v3 库冒烟 = 35 条全绿；与真 v3 边车同库同请求 **18/18 SAME**。
2. **R2**：补齐其余**纯本地**只读端点（briefing / advice / stacks / senders / sent / store-notices / time-saved / usage / actions / drafts / search），全部以 v3 的 golden fixtures 为 oracle；`search` 按正确语义重写（v3.2.0 的 pass-B 漏 JOIN `advice`，必然 500）。
3. **R3**：IMAP/SMTP（读、同步、发送）—— 这是真正让外壳可以不带 Swift 的那一步；`/body`、`/inline-images`、`/attachments` 的 200 形状在 R3 补齐 fixtures。
4. **写路径（归档/删除/回复/撤销/置顶）** 由 Rust 实现（原 M2 的后端部分并入 R3），Web 前端的写 UI 仍按契约开发，先对着 Swift 边车联调，后端替换时前端零改动。
5. 外壳在 R2 完成后增加 `--backend rust|swift` 开关（默认 rust），Swift 边车降级为「对照实现」，M4 前删除。

## 被否决的选项

- **先做 M2（写路径走 Swift 边车）再继续 Rust**：会让「发布物零 Swift」无限期推迟，且写 UI 与后端语言无关，先做前端不会浪费。
- **让 Rust 直接从零自建 schema**：R2 期间仍以 v3 的迁移链为基线，避免两套 schema 漂移；R3 交接时再接管迁移所有权。

## 后果

- 正面：R1 已证明「同一份库、同一份响应」，切换风险被契约测试兜住；前端与后端解耦，顺序可调。
- 负面：R2/R3 期间仍存在双实现对账成本；v3 的 seed/fixture 工具必须继续可用。
- 触发复审：R2 端点若出现 >1 处无法用 fixture 表达的行为差异（例如依赖 IMAP 状态的读路径），就把该端点推后到 R3。

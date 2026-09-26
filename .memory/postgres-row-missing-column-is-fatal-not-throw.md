---
name: postgres-row-missing-column-is-fatal-not-throw
description: PostgresNIO 缺列访问是 Fatal error 而非 throw——try? 救不了；任何喂共享 decode() 的 SELECT 必须带上解码器要读的每一列
type: gotcha
---

# PostgresRow 缺列是 Fatal，不是可捕获的 Error

**What happened.** 2026-09-27 加 `message_headers.is_deleted`（迁移 019）时，全量测试在
`BodyStoreTests.test_search_*` 处整进程 SIGTRAP：`PostgresRow.swift:173 Fatal error: A
column "is_deleted" does not exist`。链路 = SearchRoutes 的 SELECT 列表没加新列，但结果行
喂给了 `MessageStore.decode(row)`，而 decode 里读 `is_deleted` 的写法是
`(try? r["is_deleted"].decode(...)) ?? false` —— **`try?` 挡得住 Swift Error，挡不住
PostgresNIO 对缺列访问的 precondition trap**。

**Why.** `PostgresRow` 的下标访问在列不存在时走 fatalError（这是库的契约：列名拼错/漏列
属于程序缺陷，不该静默吞掉）。于是"防御性的 try?"恰恰变成了最危险的位置：它让人觉得这
行安全，实际上任何喂进来的 SELECT 漏一列就炸整个 xctest 进程（全量套件后续全部标失败）。

**How to apply.**
- **给共享 decode() 加列时的固定动作**：grep 该 decode 的全部调用方，逐个核对 SELECT
  列表。本次 `MessageStore.decode` 只有 DraftRoutes search 一个外部调用方，漏的就是它。
- 新增路由自己写 SELECT 时，要么列列表抄 `MessageStore.recent` 的完整清单，要么别复用
  共享 decode，自建窄解码。
- 症状识别：整进程 signal 5/Trap + "A column X does not exist"，且 X 明明在表里 ——
  那是某个 SELECT 漏列，不是迁移没跑。先查 SELECT，再查 schema。
- 反向教训：全量套件报"N targets failed"而细节被 tail 截断时，必须抓失败现场再定性；
  这次 fatal 与两个已知 flaky（[[postgres-row-missing-column-is-fatal-not-throw]] 同期
  的滚轮/并发测试抖动）混在一起，差点误判成环境抖动放过。

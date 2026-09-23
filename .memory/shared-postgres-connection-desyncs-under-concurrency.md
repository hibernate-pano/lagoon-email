---
name: shared-postgres-connection-desyncs-under-concurrency
description: 一条 PostgresConnection 同一时间只能跑一个查询——多 loop/多 task 共用必丢数据，要么每 loop 独立连接，要么走连接池
type: gotcha
---

# 共享 PostgresConnection 在并发下静默丢数据

**What happened.** V2 A1 把 `SyncEngine` 从单 loop 改成每账号一 loop，但所有 loop 共用 App 传进来的同一条 `PostgresConnection`。
测试表现为：provider 明明吐出了 `b-1`（pullCount 涨了），`message_headers` 里却永远没有这行，而 health 照常变绿
（空 round 的 apply 照样写 `last_sync_at`）。排查时 `sync.applied` 日志缺席是关键信号——pull 计数涨但 applied 不打，
说明数据死在 pull 之后、入库之前。单连接同一时间只能有一个 in-flight 查询，两个 loop 的查询在一条连接上交错，
协议错位，upsert 那句查询就这么没了，且抛出的错被当成普通 round 失败吞掉。

**Why.** postgres-nio 的 `PostgresConnection` 不是连接池。之前单 loop + 路由偶发并发，撞上的概率低所以一直没爆；
多 loop 让并发变成常态，必现。health 照绿是最坑的部分：空 round 的 apply 成功，把“这一轮啥也没干”记成了成功。

**How to apply.**
- 每个 loop 独立连接：`SyncEngine(makeDB:)` 工厂，refresh 为每账号建一条，stop/refresh 负责 close（只关自己建的，
  共享 `db` 的 owner 另有关闭者）。连接数 = 账号数，这个量级下正确性优先于池化。
- 真正的 `PostgresClient` 池等账号×流量上来再说（`LagoonPostgres.swift` 里已经预告了）。
- 测试里多 loop 必须配 `makeDB: { try await TestDatabase.requireConnection() }`，断言前确认 `sync.applied` 打了，
  别只信 `last_sync_at`。

**Related.** [[long-lived-loop-must-reread-its-row]] — 同一文件的 loop 家族问题。

---
name: multi-active-engine-syncs-stray-test-rows
description: 多活跃引擎会同步库里所有行——并行测试的 transient 行也会被扫到，脚本化 provider 必须按账号隔离
type: gotcha
---

# 多活跃引擎下，测试的 provider 必须按账号隔离

**What happened.** `SyncEngineTests.test_switch_...` 里 A/B 两个账号共用“按 id 二选一”的 `makeProvider` 闭包，
两个脚本化 provider 被两个 loop 共享。LagoonServerTests 里各测试类是并行的，`BodyStoreTests` 的 `body-` 瞬态行
正好躺在同一库里，多活跃引擎（按设计）给它也起了 loop，stray loop 抢先消费了 providerB 的 `b-1` 脚本。
证据链：`sync.applied count=1` 打在了一个 `body-` 账号上，而 B 账号 health 照绿（空 round 的 apply 照写
`last_sync_at`）——“health 绿但没数据”再次成为误导信号。

**Why.** 单活跃时代引擎只看被选中的一行，stray 行天然被忽略；多活跃把“库里有啥就同步啥”变成字面行为，
测试隔离假设就变了。共享脚本 + 多消费者 = 脚本被谁消费不确定。

**How to apply.**
- 引擎测试用 `[accountId: StubProvider]` 按账号查表，unknown 账号给空脚本默认 stub。别写 `id == x ? A : B` 这种二选一。
- 断言 `sync.applied` 日志/行级结果，别只看 health。
- `cleanup` 保持行级删除（已有纪律），但要意识到：删行之前的时间窗口里，别的测试的引擎可能已经扫到过这些行。

**Related.** [[shared-postgres-connection-desyncs-under-concurrency]] — 同一次排查的另一半。

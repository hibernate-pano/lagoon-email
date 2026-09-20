---
name: long-lived-loop-must-reread-its-row
description: 长生命周期循环对象不得持有账号行快照——游标是可变状态，快照会让每轮重复投递同一批邮件，且测试全绿
type: gotcha
---

# 长生命周期循环对象必须每轮重读自己的账号行，不能持有启动时的快照

**What happened.** 把同步引擎拆成「每账号一条 `AccountSyncLoop`」时（`SyncEngine.swift`），
`AccountSyncLoop` 在 `init` 里把 `account: Account` 存成 `let`，`round()` 用它调
`provider.pullChanges(after: account.syncState, ...)`。旧代码是单循环、每 tick 从库里
`AccountStore.active(db:)` 重读，所以从来没暴露过这个问题。

后果在一个真实邮箱上才显形：`362472407@qq.com` 的 `sync_state` 是空的（它此前不是活跃账号，
从未同步过），于是每轮都按 backfill 窗口取回同一批 168 封，`sync.applied count=168` 每 20 秒
刷一次日志——**游标写进库了，但下一轮读的仍是启动时的空快照**，永远不推进。
另一个账号（游标本来就有值）症状更隐蔽：它只在有新邮件时才返回一轮，然后重复投递那一小批。

**Why.** 循环对象的身份（id、地址、provider）是不可变的，但它**依赖的行状态不是**：`sync_state`
是每轮自己写进去的，`capabilities` 会被连接流程改，凭据会在重连时换。把「取一次的行」当成
「这个账号」来用，就等于把可变状态冻在了构造时刻。测试没抓到是因为测试多半只驱动一轮、
或给 provider 喂固定脚本——单一轮的断言对「第二轮读了什么」完全无感。

**How to apply.**
- 任何「活得比一次调用久」的循环/actor：**每轮从权威存储重读它依赖的可变状态**，只把不可变的
  身份留在属性里。别为了省一次查询而记住游标、凭据、开关。
- 代价可以忽略：每账号每轮一次小 `SELECT`（旧代码本来也这么做）。真正贵的是重复投递
  N 封邮件并写 N 次库。
- 回归测试要断言「**第二轮传给 provider 的游标 == 第一轮提交的游标**」，而不是只断言一轮的结果。
  `SyncEngineTests.test_secondRound_resumesFromThePersistedCursor` 就是这个锁；把
  `after: current.syncState` 改回 `after: account.syncState` 它会立刻红。
- 排查手法：看 `sync.applied` 的 `count=` 是否在无新邮件时反复出现同一个数字（本次是 168）。
  这类 bug 靠单测发现不了，必须对**真实**邮箱跑一遍并读日志。

**Related.** [[imap-pull-path-must-log-a-round]] — 同样是「只在自己表里的状态无法被观测」：
这次也是靠 `sync.applied` 的 count 重复才看出来的。

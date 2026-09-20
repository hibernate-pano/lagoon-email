---
name: imap-pull-path-must-log-a-round
description: IMAP 拉取路径原本完全静默，导致「已连接但没数据」与「邮箱是空的」无法区分——每账号每进程至少打一次 round 摘要
type: decision
---

# IMAP 拉取路径必须至少打一次 round 摘要日志

**Why.** 排查「登录成功但邮件不来」时，原来的日志只有 `imap.connected`，而它只说 TCP+TLS 握手成功——
`SELECT` 看到了多少封、`UID FETCH` 抓回几条，一个字都没有。于是「连接正常但同步没跑」和「邮箱本来就是
空的」在日志里完全一样，只能靠猜。加上一行 `logger.info("imap.round", metadata: [account, exists,
uidValidity, uidNext, fromUid, fetched])` 之后，一次运行就同时排除了两种假设并直接定位到读路径问题
（当时的输出：`exists=393 fetched=189 fromUid=13018 uidNext=13518 uidValidity=1384787035`，
既证明邮箱非空、也证明 FETCH 有返回）。

**How to apply.**
- 用 `loggedFirstRound` 之类的一次性门控，**每账号每进程只打一次**，避免长连接下每轮都刷日志。
- 同步失败路径同理：`markFailure` / `markAuthFailure` 会把状态写进 DB（`sync_status`），但**成功且无新邮件
  的轮次什么都不写**——这正是「看起来什么都没发生」的来源。状态要能被外部观察到，不是只写进自己的表。
- 排查手法沉淀：`last_sync_at` 是否非空 + `sync_state` 里有没有 `uidValidity`/`lastUid` 游标，是判断
  「同步到底跑过没有」最快的两个信号；两者的组合能区分「从未跑过」「跑过但没写入」「写入失败」。

**Related.** [[imap-read-must-always-park]]

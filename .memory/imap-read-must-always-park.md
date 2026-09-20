---
name: imap-read-must-always-park
description: NIOSSLStreamTransport.fillBuffer 必须永远挂起——「缓冲非空」不等于「数据够」，否则读路径 100% CPU 活锁且静默
type: gotcha
---

# IMAP 读取：`fillBuffer` 必须永远挂起，不能用「缓冲空」当循环条件

**What happened.** commit `7b1906c`（"读取改为单后台 pump"）把 `NIOSSLStreamTransport.fillBuffer()` 写成
`while pending.readableBytes == 0 { ... }`。当缓冲里**有一部分**数据（一个还没到 CRLF 的行、或一个 `{N}`
字面量只到一半）时，循环条件为假 → 立即返回且不挂起；调用方 `readLine()` / `readExactly(_:)` 的空转循环
于是 100% CPU 空转。后果是三重叠加：

1. 空转路径永远到不了 `Task.checkCancellation()`，所以 `withReadTimeout` 的超时子任务虽然抛了
   `timedOut`，但 `withThrowingTaskGroup` 必须排空所有子任务 → 整个 `readResponse` 永不返回；
2. 空转把唯一的 cooperative 池占满 → 负责投递字节的后台 pump Task 得不到调度 → **活锁**，数据永远不来；
3. 全程静默：没有超时、没有错误、没有日志，`last_sync_at` 停在 `never`。

实证手段：`sample <pid> 3` 看到一条 cooperative 线程 1901/2111 采样卡在
`readResponse → readExactly → fillBuffer → ByteBuffer.readableBytes.getter`，且 `ps` 显示 100% CPU / state=R。

**Why.** 协议是「等到有新数据」，不是「等到缓冲非空」。两个调用方各自已有完成条件循环
（`extractLine() != nil` / `readableBytes >= count`），`fillBuffer` 的职责只有挂起。把它写成条件循环
就等于把「数据够了」错当成「数据非空」，并在唯一的失败路径上跳过取消检查。

**How to apply.**
- 任何「等待生产者投递」的辅助函数：函数体单次执行，**要么挂起、要么抛错**，绝不允许立即返回。完成条件
  属于调用方的循环。
- 用 `ReadWaiter` 这类 continuation 交接时，`store()` 必须能处理「取消已经先到」的情形（带
  `cancelled` 标记，store 发现已取消就地 resume），否则 `withTaskCancellationHandler` 在任务进入时已取消
  的情况下会先执行 onCancel、`take()` 拿到 nil，随后 store 的 continuation 永远没人 resume。
- 回归测试必须构造「**部分**数据先到、剩余延后到」的场景。只测「一次投递完整响应」的测试对这个 bug 完全
  无感——这也是它能在 263 个测试全绿的情况下上线的原因。

**Related.** [[imap-pull-path-must-log-a-round]] — 这个 bug 是靠给拉取路径加一行 round 摘要日志才发现的。

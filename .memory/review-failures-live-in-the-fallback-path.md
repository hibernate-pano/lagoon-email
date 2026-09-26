---
name: review-failures-live-in-the-fallback-path
description: 三次独立 review 独立得出同一结论——happy path 正确且有测试，缺陷全在 fallback/降级路径且无测试；review 时直接审降级分支
type: gotcha
---

# 缺陷住在降级路径里，不在主路径里

**What happened.** 2026-09-24 对最近 4 个 commit 做三路独立 review（server 退订/SSRF、macOS 客户端、
v2 多活同步大 commit），三条 lane 各自独立给出同一个形状的结论：

| lane | 主路径判定 | 缺陷位置 |
|---|---|---|
| 退订/SSRF | landing-page-不算成功 ✅、DraftReply 共享类型 ✅、016 幂等 ✅ | mailto 短路中止解析链、被拦的 3xx 记成成功、stage-3 `try?` 把 provider 错误吞成「无链接」 |
| 客户端 | evalJS 通道实测可用 ✅、回归锁是真的 ✅ | 10s 测量窗口后永久停摆、降级阈值让 80pt 地板掩盖错测、降级不可重新武装 |
| v2 同步 | 复合 FK 有效 ✅、loop 每轮重读行 ✅ | sent 收割导致热轮询、to/cc 没持久化、refreshAccount 重入泄漏连接 |

**Why.** 主路径有真实环境压着（真邮箱、真 macOS 27.2 探针、真 Postgres），一写完就被真跑过；
降级路径没有触发条件——只有在「超时 / 尺寸被拒 / 对方返回 3xx / 并发重入 / 文档 10s 后才长完」
这些没人构造的场景里才成立，于是既没跑过也没测过。**测试跟着主路径走，所以绿灯只覆盖了已经
被验证过的那一半。**

**How to apply.**
- 本项目 review 时，**跳过 happy path，直奔 fallback 分支**：`try?` / `catch` 吞掉的地方、
  `guard … else { return }` 早退、超时后走的那条路、状态被 latch 成单向的地方。
- 「成功」的判定条件要单独审：本轮已修过 2xx 落地页不算成功（[[ssrf-guard-must-revalidate-redirects]]
  的姊妹坑），同一处判定里的 **3xx 也得算失败**；「有值」和「值正确」是两件事。
- 降级一旦 latch（`forwardsScrollWheel = false` 只写一次、rule 被 delete 后无恢复路径），
  一次瞬时抖动就永久改变行为——降级必须可重新武装。
- 判断一个测试是否真的有用：它能否在**降级路径**变红？只驱动一轮正常流程的测试对该类 bug 完全无感
  （[[long-lived-loop-must-reread-its-row]] 同一家族）。
- 评审产出要能回答「哪些测试锁住了这条结论」；lane 报「零覆盖」的地方就是待补清单，不要因为
  主路径全绿就跳过。

**Related.** [[shared-response-types-keep-client-server-contracts-honest]] — 同一次排查的
「服务端全 ok、客户端静默失败」；[[imap-pull-path-must-log-a-round]] — 状态必须可被外部观察，
否则「看起来什么都没发生」。

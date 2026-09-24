---
name: shared-response-types-keep-client-server-contracts-honest
description: POST /draft 服务端包 {"drafts":[…]} 信封、客户端解裸对象——每次点击都报"未能读取数据"但服务端全成功；两端共用 LagoonKit 类型的端点(如 summary)从没坏过
type: gotcha
---

# 客户端/服务端响应形状漂移:服务端全绿、UI 每次都失败

**What happened.** 生成草稿每次点击都弹"未能读取数据，因为数据丢失",但 AI 摘要一直正常。
根因不是 LLM:服务端 `capability=draft outcome=ok`、`draft_replies` 有行、`ai_actions` 有审计行——
全成功。断在最后一厘米:服务端 `POST /draft` 把响应包进本地结构 `DraftListResponse`
(`{"drafts":[…]}`),而 `APIClient.generateDrafts` 解码的是裸 `DraftReply`(要顶层 `id`/`variants`)。
`DecodingError.keyNotFound` 的 `localizedDescription` 恰好逐字等于 UI 那句"未能读取数据，因为数据丢失"。
契约从 M2+ 第一天就断了,没有任何测试锁过 POST /draft 的响应形状。

**Why summary 没事:** 摘要两端共用 `LagoonKit.MessageSummary`、服务端直接返回裸对象——形状天然一致。
草稿的信封结构只存在于 `DraftRoutes.swift` 内部,客户端看不见,于是静默漂移。

**How to apply.**
- 端点响应类型放 `LagoonKit`(两端共享),服务端本地 wrapper 结构 = 漂移温床;包装必须有对应客户端类型。
- 排查"UI 报解码错但服务端日志全 ok"时:先 `curl` 拿真实响应体,对比客户端 `decode(T.self,`
  的 T;错误文案是 Foundation 的 DecodingError 本地化字符串时,几乎一定是形状不匹配。
- 回归锁要**两侧各一把**:`DraftRouteTests`(服务端返回形状,用客户端同款 iso8601 decoder 解)+
  `APIClientTests.test_generateDrafts_oldEnvelopeShape_doesNotDecode`(旧形状必须解不出来,
  它一旦变绿=两边又漂了)。
- 测试里查 `ai_actions.kind` 用 rawValue `draft_create`(不是 case 名 `draftCreate`)。

**Related.** [[imap-pull-path-must-log-a-round]] — 同族:"每一步都该留下可观察的证据";
本次靠 outcome=ok + DB 行 + curl 响应体三角定位。

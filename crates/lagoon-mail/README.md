# lagoon-mail —— v4 邮件协议层（R3.1）

> **定位**：与 HTTP、SQLite、同步循环无关的 Rust 邮件协议层。v3.2.0 的
> IMAP / SMTP / MIME 行为按「事故—修法—测试」逐条移植，供 R3.4 同步引擎和
> R3.5 写路径复用。
>
> **硬约束**：测试零外联。全部用例走注入式脚本传输；TLS 用例是两套 rustls
> 状态机在内存里交换字节，不建 socket。当前 **196 条测试全绿**
> （115 单元 + 81 集成），`cargo test --offline -p lagoon-mail`。

## 1. 是什么 / 不是什么

| 是 | 不是 |
|---|---|
| 可注入的字节传输抽象（真实实现 = 隐式 TLS 993/465，全证书校验） | 不是 HTTP 服务，不认识 axum / serde / 路由 |
| 完整 IMAP 命令层：LOGIN、CAPABILITY、LIST、SELECT、UID SEARCH/FETCH（头/体/部分）、UID MOVE、UID STORE、UID EXPUNGE、APPEND、IDLE | 不是同步引擎：没有循环、退避、并发、状态机 |
| SMTP 投递：UTF-8 主题编码、附件、Message-ID/In-Reply-To、逐收件人 RCPT、dot-stuffing、状态码映射 | 不碰 SQLite、不迁移、不读凭据库；密钥仍由外壳持有 |
| MIME：嵌套 multipart、text/plain 优先、HTML 保留/剥离、附件与 cid 内联图、GBK/GB18030/Shift-JIS 转码 | 没有连接池、没有账号级会话上限（v3 `MailProviderPool` 属 R3.4） |
| 能力三态 + 角色文件夹（archive/trash/sent）+ UIDPLUS 闸门 | 不做 AI、摘要、退订扫描、简报 |
| 只读同步缝 `MailSyncReading`：类型上拿不到写动词 | 不改 v1/v3 一行；不复制 v3 的普通 EXPUNGE 兜底 |

## 2. 快速开始

```bash
cd crates
cargo test --offline -p lagoon-mail      # 196 passed，不联网
```

在未来的同步引擎里，读面只拿 trait：

```rust
use std::time::Duration;
use lagoon_mail::{MailError, MailSyncReading, SyncCursor};

fn sync_round(seam: &mut dyn MailSyncReading) -> Result<(), MailError> {
    // None = 本次没协商成功，必须沿用旧值，不能记成「没有能力」。
    if let Some(capabilities) = seam.capabilities() {
        let _ = capabilities.allows_purge();
    }
    let changes = seam.pull_changes(SyncCursor::default(), Duration::ZERO)?;
    // changes.removed_remote_ids 为 None 时，存储层不得删除任何本地行。
    let _ = changes;
    Ok(())
}
```

账号级动词只存在于 `ImapProvider` 上：

```rust
use lagoon_mail::{ImapProvider, ProviderCredentials, ProviderPreset};

let mut provider = ImapProvider::tls(
    ProviderPreset::qq(),
    ProviderCredentials::new(username, auth_code),
);
let capabilities = provider.capabilities();          // Option<MailCapabilities>
let body = provider.fetch_body(remote_id)?;           // 只读
let raw = provider.fetch_raw_message(remote_id)?;     // .eml
provider.set_read(remote_id, true)?;                  // 需要用户触发
provider.archive(remote_id)?;                         // 角色文件夹 + 安全 MOVE
provider.permanently_delete(remote_id)?;              // 无 UIDPLUS 必拒绝
provider.shutdown();                                  // 主动交还会话
```

SMTP 每次发送一条新 TLS 会话：

```rust
use lagoon_mail::{SmtpClient, TlsTransport, OutboundMessage};

let mut smtp = SmtpClient::new(Box::new(TlsTransport::new()));
let message_id = smtp.send(&outbound, smtp_host, 465, username, auth_code)?;
```

纯 MIME 解析（不依赖网络）：

```rust
let parsed = lagoon_mail::mime::parse(&raw_bytes);
println!("{}", parsed.text);            // text/plain 优先，HTML-only 时剥离
for attachment in parsed.attachments {  // 元数据；字节需 parse_with_options(_, true)
    println!("{} {:?}", attachment.id, attachment.filename);
}
```

## 3. 模块地图

| 路径 | 职责 |
|---|---|
| `src/error.rs` | `MailError`（kind + 静态 code + 数字 status）、`TransportError`；服务器原文没有字段可存 |
| `src/transport.rs` | `Transport` trait（connect/write/read_line/read_exact/timeout/close）+ `TlsTransport` |
| `src/tls.rs` | 生产 rustls 配置：平台信任库 + 完整校验，无“跳过验证”开关 |
| `src/preset.rs` | 固定主机表（QQ：imap.qq.com:993 / smtp.qq.com:465） |
| `src/imap/parser.rs` | 纯文本 → 结构：tag/untagged/continuation、引号、`{N}` 字面量、嵌套括号 |
| `src/imap/connection.rs` | tag 分配、字面量合并、40MB 上限、APPEND、IDLE、读超时 |
| `src/imap/client.rs` | 命令层：LOGIN/SASL、CAPABILITY、LIST/SELECT、UID SEARCH/FETCH/STORE/MOVE/EXPUNGE、APPEND |
| `src/imap/capabilities.rs` | 三态能力、角色发现、archive 一次性 CREATE、保留文件夹过滤 |
| `src/imap/membership.rs` | 单会话成员集合：FolderMembership/RemoteMembership、预算与 UID→remote id 映射 |
| `src/imap/provider.rs` | 账号级：连接复用、角色解析、安全 MOVE、UIDPLUS 闸门、只读 pull |
| `src/mime/headers.rs` | 头部展开/小写、RFC 2047、RFC 5987、地址列表、From 解析 |
| `src/mime/charset.rs` | GB18030/GBK/GB2312、UTF-8 宽松阈值、IANA 表、QP/base64 |
| `src/mime/html.rs` | HTML → 文本：去 script/style/tag、实体、空白折叠 |
| `src/mime/parser.rs` | 递归 part：嵌套 multipart、message/rfc822、附件/cid、200KB/5MB 截断 |
| `src/mime/builder.rs` | 出站 RFC 5322：base64 正文、multipart/mixed、RFC 2047 主题、filename*、头部注入清洗 |
| `src/smtp/client.rs` | SMTP 会话状态机：AUTH PLAIN、逐 RCPT、dot-stuffing、4xx/5xx 与重试规则 |
| `src/sync.rs` | `MailSyncReading`、`ChangeSet`、`RemoteHeader`、`SyncCursor` |
| `tests/support/mod.rs` | 脚本化传输（队列 line/literal/deferred/timeout/fail-next-read） |

## 4. 从 v3 抄来的事故教训

1. **隐式 TLS + 全证书校验**（`ProviderPresets.swift`、v3 NIO SSL 传输）。
   993/465 之外不裸露明文；主机只来自预设，用户输入进不了连接目标。
   自签或漏链必须失败——没有“先继续、稍后提示”的降级路径。
2. **字面量上限 40MB**（`IMAPConnection.maxLiteralBytes`）。v3 曾是 32MB：
   25MB 附件 base64 后约 33.3MB，被当作服务器错误；上限按“最坏合法消息 + 余量”
   定，不是拍脑袋。超限是 413 类稳定码 `literal-too-large`，不是 502。
3. **同步永远用 `BODY.PEEK`**，不用 `BODY`。拉头、拉正文、拉预览都不能把邮件
   标成已读。
4. **UIDPLUS 闸门**（`IMAPProvider.permanentlyDelete`）。`UID EXPUNGE` 是唯一
   “只删这一封”的命令；没有 UIDPLUS 就返回 `capability-missing`，**且在发任何
   命令之前**返回。普通 `EXPUNGE` 会删同文件夹里别的客户端标了 `\Deleted` 的
   信，不可撤销——本 crate 的 IMAP API 里根本没有普通 EXPUNGE 方法。
5. **无 MOVE 的安全兜底**：`UID COPY` + `UID STORE \Deleted` + `UID EXPUNGE`。
   若连 UIDPLUS 也没有，`archive` / `move_message` 直接 `unsafe-operation`，
   不 COPY、不 STORE。v3 的 `deleteExactly` 兜底包含普通 EXPUNGE，R3 明确禁止。
6. **角色文件夹**（`resolveArchiveFolder` / `isTrashMailbox` / `isSentMailbox`）：
   SPECIAL-USE 优先；否则按叶子名（大小写不敏感，含 `废纸篓/已删除/已发送/归档`，
   兼容 `QQ/废纸篓` 这种嵌套路径）。archive 缺失时 CREATE 一次；trash/sent 缺失
   就报 `trash-unavailable` / `sent-unavailable`，绝不伪造一个“Trash”来假装
   删除语义。
7. **能力三态**（`MailCapabilities.swift`）：`archive_folder` / `trash_folder` /
   `sent_folder` / `uidplus` 是 `Option<bool>`。`None` 表示未探测，闸门按
   “允许”处理（服务器是权威）；只有 `Some(false)` 才关闭。v3 的
   `archiveFolder` 曾被当成纯 Bool，未协商的账号行带 all-false 默认，归档被
   永久 409。
8. **SMTP 重试与终态**（`SMTPClient`）：DATA 之前失败可重试一次完整会话；
   DATA 之后终态，绝不重试（否则收件人收到两封）。QUIT / 221 永不失败发送——
   250 已表示入队。4xx = 会话级、可重试；5xx = 终态。RCPT 逐个：单地址 5xx 跳过，
   其余照发；一个都没接受 = 失败；空信封 = `smtp-no-recipient`。
9. **服务器原文不进错误**：v3 的状态码映射就是因为 550 文本会带收件人地址。
   本 crate 的 `MailError` 只有静态 code + 数字 status，测试断言错误 Display 里
   连一个 `@` 都没有。
10. **MIME 的 LF-only 陷阱**：边界只认 CRLF 前的 `--boundary`；若直接搜
    `\n--boundary` 会在每个 CRLF 中间多匹配一次，把每个 part 劈成两半。做法是
    先把正文整体补成 CRLF 框架，再只搜一次 CRLF 边界（`crlf_framed`）。
11. **message/rfc822 两种形态**：`Content-Disposition: attachment` 的转发是
    “整封 .eml 附件”，不再递归吞正文；inline 的转发保留原信文本 + 可下载的
    .eml，且**不把内层 HTML 提升成外层 HTML**（否则详情页显示的是被转发内容，
    而不是发件人写的那段话）。
12. **内联图 cid**：无 disposition 的 image/* 默认 inline，Content-ID 去掉尖括号，
    供 `cid:` 解析；正文解析默认不解码附件字节（`parse`），下载路由才
    `parse_with_options(_, true)`。
13. **字符集**：`gbk/gb2312/gb18030/cp936` 全走 GB18030（GBK/GB2312 是子集）；
    UTF-8 严格失败后，只有“替换字符 ≤1%”才保留宽松结果（截断窗口的尾字节），
    否则按 Latin-1 兜底；`windows-1252` 与 v3 一样映射 Latin-1。GBK 正文、
    Shift-JIS 编码词都有用例。
14. **RFC 2047 / 5987**：相邻编码词之间的空白被丢弃（否则中文主题多空格）；
    `filename*` 的百分号转义必须真正解码，否则中文附件名到客户端是乱码；发送侧
    同时写 `filename` 与 `filename*`。
15. **头部注入**：回复的 subject / In-Reply-To / References 都来自远程邮件，
    RFC 2047 解码可能还原出 CRLF。所有出站头部值统一去掉 CR/LF/NUL；subject
    先做编码词再清洗，防止 `\r\nBcc:` 伪造一行。
16. **首同步按“邮件数”不是“UID 槽位”**（`backfillWindow`）：v3 实测一个 QQ
    邮箱 13733 个 UID 槽只有 265 封，按 UID 取 500 只能覆盖最新 43 封。
    `fetch_newest_headers(count, exists)` 用序列号窗口，`pull_changes` 首轮
    500 封；增量才用 `UID FETCH cursor:uid_next`。
17. **地址列表只按顶层逗号切**（`AddressList`）：引号/尖括号内的逗号属于显示名；
    收件人信封逐条 RCPT、按大小写不敏感去重。v3 的三个 splitter 各自实现、互相
    打架，正是发送失败的来源。
18. **只读宪法**（`MailSyncReading`）：同步引擎持有的是 trait，编译期没有
    archive/setRead/trash/send 可调。`ChangeSet.removed_remote_ids` 为 `None`
    表示“未知”，存储层不得据此删行。

## 5. 与 v3 的刻意差异

- **阻塞传输**：R3.4 用 `spawn_blocking` 驱动。测试因此不需要 runtime、计时器或
  取消语义，字节级确定性更好；IMAP 仍是严格串行、无 pipelining。
- **rustls-platform-verifier 替代 rustls-native-certs**：本机离线 registry 没有
  `rustls-native-certs`；平台验证器读取同一套系统信任库（macOS Security.framework，
  Linux/Windows 各自系统库），仍是完整链校验 + 主机名校验，且没有任何
  `dangerous()` 关闭验证的入口。TLS 拒绝用例跑的是**生产配置**本身。
- **附件大小估计修正**：v3 的 QP 估算只检查每第三个字节；这里改为扫描 `=XX` 与
  软换行。仅影响 UI 显示的大小，不改变解码字节。
- **尾随注释地址修正**：v3 的 `stripComment` 实际只去掉空注释，`bob@x (Bob)`
  会被整条丢弃；这里按注释语义剥离后缀，保证收件人不会静默消失（有单测）。
- **错误类型结构化**：`MailError { kind, code, status }`，服务器原文不可能混入。
- **角色缓存范围**：按会话缓存 capability/roles；archive CREATE 被拒后锁存到本次
  会话结束。v3 的负结果 TTL 属同步引擎策略（R3.4）。
- **SMTP 信封地址校验**：增加 CR/LF/空白/尖括号检查（v3 依赖上游先清洗），
  非法地址在写 RCPT 前拒绝。

## 6. 测试：196 条，零外联

| 套件 | 数量 | 内容 |
|---|---:|---|
| 单元（`src/**`） | 115 | IMAP 解析器全部 v3 用例、头部/RFC2047/地址、GBK/Shift-JIS、QP/base64、HTML、MIME 递归、MIME builder + 注入、SMTP dot-stuffing、时间格式、能力三态 |
| `tests/imap_connection.rs` | 15 | greeting、tag、字面量合并、40MB 拒绝、NO/BAD → 类型化错误、continuation、APPEND、IDLE 事件/超时/拒绝 |
| `tests/imap_client.rs` | 19 | SASL-IR + LOGIN 回退、CAPABILITY 缓存、SELECT/LIST、FETCH 头、序列号窗口、flags、SEARCH ALL/Message-ID、STORE、MOVE 能力闸门、UID EXPUNGE、BODY.PEEK、参数注入 |
| `tests/imap_provider.rs` | 23 | 能力/角色一 LIST 定三态、archive CREATE/拒绝、UIDPLUS=false 永久删除拒绝（断言无 STORE/EXPUNGE）、UIDPLUS 删除、清空废纸篓、MOVE/无 MOVE 兜底、无 UIDPLUS 拒绝归档、GBK 正文、附件、建文件夹移动、list_folders、Sent、pull + UIDVALIDITY 重置、probe、shutdown、只读缝 |
| `tests/smtp_delivery.rs` | 16 | 完整命令序列、主题编码、线程头、逐 RCPT（含 Cc/Bcc）、AUTH 4xx/5xx、DATA 前重试、DATA 后终态、部分收件人拒绝、4xx 收件人重试、空信封、CRLF 注入、dot-stuffing、QUIT 失败不影响、服务器原文不泄漏 |
| `tests/imap_membership.rs` | 7 | 单会话 INBOX/archive/trash：三集合/缺 archive/EXISTS 超限/UID 超限/无权限 SELECT/超时/SELECT 前 LIST 失败；每例断言 connects=1 |
| `tests/tls_reject.rs` | 1 | 生产 rustls 配置 + 内嵌自签证书，在内存中完成握手并断言失败 |
| 文档测试 | 0 | — |

**零外联证据**：所有协议用例都构造 `tests/support` 的脚本传输；没有任何测试实例化
`TlsTransport` 或调用 `TcpStream`。TLS 套件只用 `include_bytes!` 的 DER 证书和两套
rustls 状态机。`tests/fixtures/` 是自签测试证书（非真实域名、非真实 CA），
只用于证明“必须拒绝”。

未覆盖（见 §7）：对真实服务器的联调、`fetch_text_snippets`、多轮 IDLE、连接池。

## 7. 边界与明确未做项

- **同步引擎 / 存储 / HTTP 全不在本 crate**。R3.4 负责 UIDVALIDITY 重置后的清库、
  成员集合推导、退避、单写者；`pull_changes` 只抓头，成员的获取由
  `remote_membership()` 在同一会话按需完成（见 §10），`None` 一律是未知、
  调用方不得据此删行。
- **没有连接池**，也没有 QQ 并发会话上限（v3 `MailProviderPool` 属 R3.4）。
- **没有 UID ↔ Message-ID 缓存**：`resolve_uid` 先 SEARCH，再扫最近 500 个 UID 的
  头部。v3 在 provider 里维护过缓存；R3.4 应把它放到有 UIDVALIDITY 生命周期的层。
- **没有退订扫描**（`UnsubscribeScanner`）：只保留 `list-unsubscribe` 的存在性布尔。
- **附件下载沿用 v3 形态**：拉整封再解码所有附件（`BODY.PEEK[]`）；`ImapClient::fetch_part`
  已提供并做了路径校验，但 provider 未走单 part 快路径。
- **没有草稿/Junk 角色语义**（仅在文件夹选择器里排除）；HTML 用轻量剥离器，不是 DOM。
- **没有 290s IDLE 预算循环**：`IMAP 连接` 提供带超时的 `idle`，节奏由 R3.4 决定。
- **未做真实账号联调**（硬约束：测试零外联）；TLS 传输的真实 socket 路径在本环境
  无法端到端验证，只有配置与拒绝路径由测试钉住。
- 发布物与 v1 未改动；v3 Swift 只作为只读参考。

## 8. 依赖与构建

| crate | 版本 | 原因 |
|---|---|---|
| `base64` | 0.22 | RFC 2047 B / SASL / body 编码 |
| `encoding_rs` | 0.8 | GBK / GB18030 / Shift-JIS 及 IANA 表 |
| `rustls` | 0.23（`ring` + `std` + `tls12`） | 隐式 TLS、TLS 1.2/1.3 |
| `rustls-platform-verifier` | 0.7 | 系统信任库 + 完整校验 |

依赖全部取自本机离线 registry，版本由 `crates/Cargo.lock` 钉住；未执行
`cargo install`，未引入全局工具。加依赖导致 `crates/Cargo.lock` 自动更新（生成的
共享文件，异常已在交付说明中报告）。`aes-gcm = 0.10.3` 未改动。

```bash
cd crates && cargo test --offline -p lagoon-mail
```

## 9. 文件清单

```text
src/lib.rs                 re-export + 分层说明
src/error.rs               错误码与传输错误
src/transport.rs           Transport trait + TLS 实现
src/tls.rs                 rustls 配置（平台验证器）
src/preset.rs              QQ 端点
src/timefmt.rs             RFC 5322 / IMAP 日期
src/imap/{parser,connection,client,capabilities,membership,provider}.rs
src/mime/{headers,charset,html,parser,builder}.rs
src/smtp/{mod,client}.rs
src/sync.rs
tests/support/mod.rs       脚本传输
tests/{imap_connection,imap_client,imap_membership,imap_provider,smtp_delivery,tls_reject}.rs
tests/fixtures/           自签测试证书（只用于拒绝用例）
```

## 10. 单会话成员集合（R3.4b-2a）

lagoon-api 的 pull_changes 需要 inbox/archive/trash 的完整成员。以前每轮额外开 3 条
连接查成员，每次都要重新 LOGIN；QQ 对单账号并发会话有上限，分层上也不该让 HTTP 层
碰 IMAP。现在：

```rust
let membership = provider.remote_membership();          // 默认预算 5000
// 或 provider.remote_membership_with_budget(2000);
let inbox = membership.inbox_remote_ids();              // Option<Vec<String>>
let archived = membership.archived_remote_ids();
let trashed = membership.trashed_remote_ids();
```

- 一次调用、**同一条已登录会话**：LIST（仅当角色未缓存）→ 依次 SELECT
  INBOX/archive/trash → UID SEARCH ALL → 按 UID 取 Message-ID（没有则 `uid:N`）。
  不要求 MOVE/UIDPLUS。
- `FolderMembership { uids, remote_ids }`：`uids` 是协议原生 UID 集合，
  `remote_ids` 是存储身份（Message-ID 或 `uid:N`），可直接填入
  lagoon-api 的 `inbox_remote_ids` / `archived_remote_ids` /
  `trashed_remote_ids`。
- 每个字段独立三态：**`None` = 未知**（文件夹不存在/无权限/超过预算/
  SELECT·SEARCH·FETCH 失败/会话断开）；`Some(empty)` = 服务器确认文件夹存在且为空。
  **调用方必须把 None 当未知，不得据此删除本地行**；只有 `is_complete()` 为真才可
  推导“已从所有可达文件夹消失”。
- 预算是 `DEFAULT_MEMBERSHIP_BUDGET = 5000`，同时限制 `EXISTS` 与
  `UID SEARCH ALL` 的结果；超限返回 None，绝不返回截断集合。
- 读路径不 CREATE 缺失的 archive（与 `capabilities()` 的“探测 + 创建”不同）：
  查询成员不能改邮箱，而且刚建的空 Archive 会让“归档的本地行全都该删”这个推导
  成立，风险方向错误。角色发现复用 `discover_roles`（SPECIAL-USE / 叶子名 /
  中文名），不重写。


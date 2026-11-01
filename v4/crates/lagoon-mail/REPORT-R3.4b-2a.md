# REPORT — R3.4b-2a：lagoon-mail 单会话成员集合

## 1. 结论

已完成并验收：

- `ImapProvider::remote_membership()`（默认预算 5000）与
  `remote_membership_with_budget(budget)` 已提供。
- 一次调用只用**一条已登录的 IMAP 会话**：LIST（角色未缓存时）→ SELECT
  INBOX / archive / trash → `UID SEARCH ALL` → 按 UID 取 `Message-ID`，
  全程复用同一个 `ImapClient`，不会为每个文件夹新建连接。
- 每个文件夹独立三态：`None` = 未知；`Some(FolderMembership)` = 完整已知
  （空文件夹也是 `Some(empty)`）。缺失文件夹、无权限、EXISTS 或 UID 数超预算、
  SELECT/SEARCH/FETCH 失败、会话断开都返回该文件夹 `None`，不 panic、不截断。
- `FolderMembership` 同时保留协议原生 `uids` 和存储身份 `remote_ids`
  （Message-ID，缺失时 `uid:<n>`），后者可直接填 lagoon-api 的
  `inbox_remote_ids` / `archived_remote_ids` / `trashed_remote_ids`。
- 角色发现复用 `discover_roles`（SPECIAL-USE / 叶子名 / 中文名），没有重写；
  读取成员不要求 MOVE 或 UIDPLUS。读路径不 CREATE 缺失的 archive（见 §4）。

## 2. 公开接口

```rust
use lagoon_mail::{FolderMembership, RemoteMembership, DEFAULT_MEMBERSHIP_BUDGET};

impl ImapProvider {
    /// 默认预算 5000；三文件夹 + UID SEARCH ALL + Message-ID 映射，一条会话。
    pub fn remote_membership(&mut self) -> RemoteMembership;

    /// 显式预算（测试/嵌入方用）。
    pub fn remote_membership_with_budget(&mut self, budget: usize) -> RemoteMembership;
}

pub struct FolderMembership {
    pub uids: BTreeSet<i64>,
    pub remote_ids: BTreeSet<String>,
}

pub struct RemoteMembership {
    pub inbox: Option<FolderMembership>,
    pub archive: Option<FolderMembership>,
    pub trash: Option<FolderMembership>,
}

impl RemoteMembership {
    pub fn is_complete(&self) -> bool;                 // 三个都 Some 才可推导删除
    pub fn inbox_remote_ids(&self) -> Option<Vec<String>>;
    pub fn archived_remote_ids(&self) -> Option<Vec<String>>;
    pub fn trashed_remote_ids(&self) -> Option<Vec<String>>;
}
```

lagoon-api 适配层可直接替换原来的三次 `membership(folder)` 调用：

```rust
let membership = provider.remote_membership();
let inbox = membership.inbox_remote_ids();
let archived = membership.archived_remote_ids();
let trashed = membership.trashed_remote_ids();
// 任一为 None → 不得推导删除；只有三者都 Some 才能算 known membership。
```

## 3. 实现要点

- `src/imap/membership.rs`
  - `DEFAULT_MEMBERSHIP_BUDGET = 5000`（对齐 lagoon-api adapter 的
    `MEMBERSHIP_BUDGET`）。
  - `collect_folder`：SELECT → 检查 `EXISTS > budget` → `UID SEARCH ALL` →
    检查 UID 数 → 按 `fetch_headers_for_uids(["MESSAGE-ID"])` 映射；返回的
    header UID 集合必须与 SEARCH 集合完全一致，否则整个文件夹 `None`（不完整
    集合绝不能伪装成完整，否则会授权错误删除）。
- `src/imap/provider.rs`
  - `remote_membership_with_budget` 在一个 `with_client` 闭包里完成 LIST +
    三次 SELECT/SEARCH/FETCH；角色从 `self.roles` 缓存或本次 LIST 的
    `discover_roles` 得到。
  - 任何 `Unreachable`/`AuthFailed` 错误把本次会话标记为 dead：剩余文件夹
    直接 `None`，结束时 `drop_connection` 关闭 socket；不会在同一轮里重连。
  - 列表/角色发现失败（包括 SELECT 前的 LIST 失败）返回全 `None`，连接计数仍为 1。
  - archive 缺失时 `None`，不调用 CREATE；trash 缺失同理。
- 没有改动 `lagoon-api`；adapter 的改造属于后续任务。

## 4. 与 `capabilities()` 的差异（有意为之）

`capabilities()` 是“探测 + 确保 archive 可用”，缺失 archive 时会 CREATE 一次；
成员读取是**同步路径上的只读查询**，不能产生副作用：

1. 新建一个空 Archive 会让“本地已归档的行都不在服务器 Archive 中”成立，从而
   可能推导出错误删除；
2. 每次同步轮都尝试 CREATE 也会在无权限账号上产生额外命令。

因此 `remote_membership` 只使用 `discover_roles`（SPECIAL-USE / 名字启发），
缺失即 `None`。如果未来产品明确要求“同步时自动建 archive”，应放在 connect/probe
或显式的账号修复流程里，而不是成员读取里。

## 5. 测试与验收

新增 `tests/imap_membership.rs`（7 条），全部用 `ScriptedTransport`，每一条都
断言 `connect_count == 1`：

1. 三文件夹都有：INBOX 2 封（含一个无 Message-ID → `uid:11`）、archive 空、
   trash 1 封；断言 UID/remote id 集合与命令序列；
2. 缺 archive：archive=`None`，inbox/trash=`Some`；
3. EXISTS=5001 > 预算 5000：inbox=`None`，且不发出该文件夹的 SEARCH；
4. 自定义预算 2 + SEARCH 返回 3 个 UID：inbox=`None`，不做 header walk；
5. archive SELECT 被 `NO [NOPERM]` 拒绝：archive=`None`，其余仍完成；
6. archive SELECT 超时：archive/trash=`None`，inbox 已知，不 panic，连接只开 1 次；
7. SELECT 前的 LIST 失败：三个都 `None`，不再发 SELECT，不重连。

命令：

```bash
cd v4/crates && cargo test --offline -p lagoon-mail
```

结果：**196 passed / 0 failed**（115 单元 + 81 集成），`cargo fmt -p lagoon-mail
--check` 通过，无 warning。

## 6. 未做 / 边界

- 未改 `lagoon-api`（约束）；adapter 接线由后续 R3.4b-2b 完成。
- 未做真实 QQ 联调（项目硬约束：测试零外联）；所有协议字节来自脚本。
- 预算内取全量 header 是为把 UID 映射成存储身份；若后续只需要 UID 集合，可加
  一个不取 header 的轻量入口（本次不改变现有 API）。
- 不处理 UIDVALIDITY 变化：调用方（lagoon-api 的 pull_changes）已有
  `reset_required` 分支，重置轮不取成员（沿用原 adapter 规则）。

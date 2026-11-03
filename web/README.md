# v4/web · M1 前端（Vite + React + TS，只读）

> 契约：docs/ipc-contract.md（外壳↔前端）、docs/m1-checklist.md（验收）、recon/server-contract.md（端点真相）。
> 这一版**只读**：连接账号是唯一允许的写（本地建账号 + 一次 IMAP 探活，不改远端邮箱）。

## 怎么跑

```bash
# 1) 边车（会写 v4/.dev/{keys.json,web.env}）
bash v4/scripts/sidecar-dev.sh start
bash v4/scripts/sidecar-dev.sh status      # healthy (pid … port …)

# 2) 前端（浏览器模式，Playwright 用这个）
cd v4/web
npm install
npm run dev                               # Vite 打印实际地址，默认 5173

# 3) 生产构建（Tauri 用 dist/）
npm run build
```

打开 Vite 打印的地址（默认 `http://127.0.0.1:5173`）。端口被占时 Vite 自动 +1，**看它打印的那行**。
边车重启会换端口/密钥 → 也要重启 `npm run dev`（dev 代理在启动时读 web.env）。

## 浏览器模式为什么走代理（与契约 §5 的差异，重要）

ipc-contract.md §5 写的是「浏览器用 fetch 直连 + VITE_SIDECAR_TOKEN」。**这条路在本服务端上走不通**：
v3 服务端零 CORS（recon/server-contract.md §9 逐条测过），跨源 fetch 会发出去但读不到响应。
给 Swift 加 CORS = 改 v1，禁止。

所以浏览器模式改走 Vite 同源代理：

```
页面  →  /api/...                          同源，无 CORS
代理  →  http://127.0.0.1:<port>/api/...    + Authorization: Bearer <token>
```

结果比契约要求更严：**token 根本不进浏览器**（不在 JS、不在内存、不在 localStorage/cookie/DOM）。
生产路径不受影响：Tauri 模式走 `invoke("api")`，这段代理只在 `vite dev` 存在。
建议 Lead 把契约 §5 措辞改成「浏览器模式经由 dev 代理」；我可以给 patch（不改 v4/docs 是我的纪律）。

## 目录

```
src/
├── core/       api.ts（唯一 HTTP 入口，双模式）· async.ts（六态模型）
│               errors.ts（错误码→文案）· hooks.ts（轮询/启动探活）· router.ts（hash 路由）
├── l10n/zh.ts  全部用户文案（中文优先，一处）
├── styles/     tokens.css（从 Swift 主题提取）· app.css
├── ui/         AsyncSurface（六态渲染器）· MailRow · AdviceStrip · atoms（Banner/TriBadge/Avatar）
└── screens/    BootScreen · Onboarding · Sidebar · BriefingFeed · MessageList
                ReaderPanel（含 SummaryPanel）· HtmlFrame · CommandPalette · ShortcutsDialog · StatesGallery
```

## 六态与三个「不知道」怎么落地

只有一个渲染器：`ui/AsyncSurface.tsx`。`Outcome<T>` 的 phase 只有六个：

| phase | 谁产生 | 界面 |
|---|---|---|
| loading | 请求在飞 | 转圈 + 文案 |
| ready | 2xx 有数据 | 渲染 rows（`notes` 非空时先叠一条「部分完成」横幅） |
| empty | 2xx 且判定为空 | 该透镜自己的空态文案 + 下一步 |
| error | `ok:false`（连接/超时）或 4xx/5xx 且无语义映射 | 标题 + 原因 + 错误码 + 重试（仅 5xx/408/429 给重试） |
| offline | `navigator.onLine === false` | 独立细条（不是横幅：状态≠失败） |
| unavailable | 401 / 未就绪 / 未连接 / 能力缺失 | 说明 + 出口（连接、去设置…） |

三个「不知道」不在 phase 里，因为它们是**值**的属性而不是请求的状态：

1. **未探测 ≠ 否** → `ui/atoms.tsx` 的 `TriBadge`：`undefined → 未探测（不代表不支持）`、`false → 不支持`、`true → 支持`。阅读器底部用它展示 `archiveFolder / trashFolder / uidplus / sentFolder`。
2. **读不到 ≠ 不存在** → 401 走 `unavailable`（`core/errors.ts` 的 `UNAUTHORIZED`），文案明确说「token 没带上/带错」，不是「网络错误」。
3. **没设过 ≠ 0** → 可选字段保持 `undefined`，界面显示 `—`（列表 `totalCount` 缺失、侧边栏计数未知时都是 `—`，不是 0）。

自检页：`#/dev/states`（标注「示例数据」，不需要账号、不连服务端）。含六态卡、三态徽章、每个透镜的空态文案、以及一块 **HTML 沙箱自检**。

## HTML 邮件怎么渲染（隐私）

`screens/HtmlFrame.tsx`：`<iframe sandbox="" srcdoc referrerpolicy="no-referrer">`，srcdoc 里注入：

- CSP：`default-src 'none'; img-src data: blob:; style-src 'unsafe-inline'`（禁脚本/禁远程/禁表单/禁导航）
- v3 的 fluid CSS 原文（HTMLMessageView.swift:480-488）
- `cid:` → `data:<mime>;base64,…`（mime 先取附件 mimeType，取不到按魔数嗅探）

实测（Chrome，本次）：`data:image/png;base64,…` 200；`https://example.com/pixel.png` 被 CSP 拦掉（network 面板标记 csp，无出网）；父页面读不到子文档（opaque origin）。

**已知差距**：v3 测量文档高度把 WebView 撑到内容高（单滚动条）；禁脚本后无法在框内测量，所以这里固定高 + 框内滚动。保真让位于隐私规则，文件头已写明。

## 搜索：客户端过滤，不发请求（按 m1-checklist §1.1）

`GET /api/search` 在 v3.2.0 必然 500（pass-B SQL 引用未 JOIN 的 advice 别名），**M1 不调用**。
列表页搜索框对**已加载的 messages** 过滤（主题/发件人/snippet，前 1000 条）：`MessageList.tsx`。
因此搜索结果态只有「有匹配 / 无匹配」，不存在「搜索失败」——这是不调用坏端点的诚实结果。

## 与契约/清单的三处已知偏差（写在这里，不做暗改）

1. **浏览器模式走 dev 代理，不是直连 fetch**（原因见上；契约 §5 需改措辞）。
2. **`POST /read` 默认关闭**（`core/config.ts` 的 `ENABLE_MARK_READ = false`）。
   m1-checklist §2 写「停留后 POST /read（record=false 保持 M1 只读）」，但该端点会 `UID STORE \Seen`——是真写远端邮箱，
   与「M1 不改远端邮箱」冲突；`record=false` 只是不写审计行。改一行常量即可打开。
3. **S2「每个透镜有独立空态」在空库下不可达**：无账号时首页按清单显示连接引导（不是空列表），侧边栏进不去列表。
   替代验证：`#/dev/states` 的「每个透镜的空态文案」卡；真机验证需要一次真实授权码。

## 键盘

| 键 | 作用 | 说明 |
|---|---|---|
| ⌘K | 命令面板 | 再按一次关闭 |
| ↑ / ↓ | 移动高亮 | 输入框内不抢 |
| Enter | 在阅读器打开高亮行 | |
| Esc | 关面板 / 取消选中 | |
| ⌘/ | 快捷键表 | |

系统键（⌘N/⌘T/⌘W/⌘Q）一律不注册。

## 验证记录（2026-10-29，空库 + 真实边车）

| 项 | 结果 |
|---|---|
| `npm run build` | ✅ 通过（tsc -b 严格模式 + vite build，56 modules） |
| `npm run dev` | ✅ 起得来（端口被占自动 +1，本次 5174） |
| 真实状态 | ✅ 顶栏「边车已连接 · http://127.0.0.1:52728 · 0 个账号」+「AI: 未配置」；引导页正常 |
| 同源代理 | ✅ `/api/accounts → 200 []`、`/api/ai-status → 200`（代理注入 Bearer，页面无 token） |
| token 泄漏 | ✅ localStorage/sessionStorage/cookie/DOM 均无；`dist/` 产物不含 token 与端口 |
| 控制台 | ✅ 无报错（仅 Vite / React DevTools 提示） |
| 六态自检 | ✅ `#/dev/states` 七张卡全渲染 |
| HTML 沙箱 | ✅ cid 图渲染；远程图 CSP 拦截；子文档 opaque origin |

## 没做（M2 及以后）

归档/删除/置顶/回复/草稿/撤销全部禁用并标「M2」；附件下载、`.eml` 导出、退订、打印、QuickLook 不在 M1；
服务端搜索、提醒、发件人排行、分组编辑留给 M2+；Tauri 外壳由 `v4/shell` 提供（本目录只认 `invoke("api")`）。
## M2 · 写路径（本次新增）

| 面 | 实现 | 端点 |
|---|---|---|
| 单条 | 归档 / 取消归档 / 移废纸篓 / 恢复 / 彻底删除（二次确认） / 置顶 / 标已读未读（record=true） | POST /api/messages/:id/{archive,unarchive,delete,restore,purge,pin,read} |
| 批量 | 多选（Shift 范围、⌘A 全选）→ 归档所选 / 删除所选 | POST /api/archive-bulk · /api/delete-bulk（按 items[] 逐条判定） |
| 文件夹级 | 清空废纸篓（强确认） | POST /api/trash/empty |
| 撤销 | 成功动作的 actionId → 底部 toast「⌘Z 撤销」→ 撤销 | POST /api/actions/:id/undo · /api/actions/undo-bulk |
| 动作历史 | 面板分页（before=actionId），逐行撤销 | GET /api/actions |
| 键盘 | ⌘Z ⌘⌫ ⇧⌘A ⌘A J/K ↑↓ Enter P Esc ⌘K ⌘/ | — |

**乐观更新与回滚**：core/mutations.ts 的 overlay（render = server − removed + patched）。每次乐观改动返回自己的 rollback；失败时**先回滚再出横幅**，所以界面不会停留在它声称做完的状态。批量先整体回滚，再只重新隐去服务端真正成功的那些行。

**失败分类**（core/writes.ts classifyFailure + core/errors.ts 文案）：
capability（409 archive-unavailable / delete-unavailable / not-in-trash、503 provider-not-configured）→「服务器不支持这个操作」，不给重试；conflict（already-undone / action-expired / not-undoable / send-in-flight）→ 各自独立文案；gone（410 message-gone）；notfound；unauthorized；transport；server。

**能力闸门**：allows(x) = x !== false（与 MailCapabilities.swift:121-156 一致）；false → 按钮禁用并在 title 说明；nil（未探测）→ 允许，由服务端 409 裁决。

**验证用开关**：`?bypass-caps=1`（仅 dev）让按钮在 capabilities=false 时仍可点，用来从浏览器打到真实 409。默认不开。

### 写路径怎么验（不需要真实邮箱）

```bash
bash web/scripts/synth-sidecar.sh start     # 合成账号 + 5 封邮件 + 审计行（临时库，凭据不可解 → 远端必失败）
cd web && LAGOON_WEB_ENV=web/.synth/web.env npm run dev -- --port 5190
# 打开 http://127.0.0.1:5190/?bypass-caps=1#/list/inbox
# 收工：bash web/scripts/synth-sidecar.sh stop
```

`LAGOON_WEB_ENV` 是**相对仓库根目录**的路径（vite.config.ts 这么读，见该文件顶部注释）。
脚本只写 `web/.synth/`（已 gitignore），不碰 `.dev/` 里的真实库。

合成账号的 capabilities 全为 false（archiveFolder/trashFolder/uidplus/sentFolder），所以：归档 → 409；置顶/标已读 → 200 且带 actionId（本地动作，可撤销）。

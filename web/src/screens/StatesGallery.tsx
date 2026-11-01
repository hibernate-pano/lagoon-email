/**
 * Six-state self-check (task-6 §4). Example data, clearly labelled.
 *
 * Why a gallery exists at all: with an empty database the real app can only
 * reach "unavailable" and "empty", so the other four states would ship
 * unrendered and unverified. Rendering them from fixtures is also the only way
 * to prove the one rule that matters — a failure must not look like an empty
 * list — without a mailbox.
 *
 * It is *not* a mock of the server: nothing here pretends to be real data, and
 * the page never talks to the sidecar.
 */
import type { ReactNode } from "react";
import { AsyncSurface } from "../ui/AsyncSurface";
import { TriBadge, Banner } from "../ui/atoms";
import type { Outcome } from "../core/async";
import { t } from "../l10n/zh";
import type { MessageHeader } from "../core/types";
import { HtmlFrame } from "./HtmlFrame";

/** 1×1 PNG: enough to prove a data: URL renders inside the sandbox. */
const PIXEL_PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

/**
 * A document that tries everything the privacy rule forbids. If the frame ever
 * starts loading one of these, the CSP or the sandbox has regressed.
 */
const SANDBOX_HTML = [
  "<p>1) cid 内联图（应显示）：<img src=\"cid:demo\" width=\"32\" height=\"32\" alt=\"inline\"></p>",
  "<p>2) 远程图片（应被拦掉）：<img src=\"https://example.com/pixel.png\" width=\"32\" height=\"32\" alt=\"remote\"></p>",
  "<p>3) 内联样式（应生效）：<span style=\"color:#1F6F84\">teal text</span></p>",
  "<script>document.body.dataset.scriptRan = 'yes';</script>",
  "<p>4) 脚本（不应执行；本卡无法自证，但 Playwright 可断言无 example.com 请求）</p>",
].join("\n");

const SAMPLE: MessageHeader = {
  id: "00000000-0000-0000-0000-000000000001",
  accountId: "00000000-0000-0000-0000-0000000000aa",
  remoteId: "sample-1",
  fromAddress: "you@qq.com",
  fromName: "示例发件人",
  subject: "这是一封示例邮件的主题",
  snippet: "这是 snippet：摘要由服务端解封后返回，前端只负责显示。",
  receivedAt: new Date().toISOString(),
  isRead: false,
  isArchived: false,
  isDeleted: false,
  isPinned: false,
  isSent: false,
};

function Card(props: { title: string; children: ReactNode }): ReactNode {
  return (
    <div className="gallery-card">
      <header>
        {props.title} <span className="badge demo">{t.app.demoBadge}</span>
      </header>
      <div className="body">{props.children}</div>
    </div>
  );
}

type Case = "loading" | "empty" | "ready" | "partial" | "error" | "offline" | "unavailable";

/**
 * "partial" is not a phase of its own: it is ready data plus notes — that is
 * exactly the shape the server produces (rows + omittedCount), and collapsing it
 * to a separate phase would lose the rows.
 */
function rowOutcome(phase: Case): Outcome<MessageHeader[]> {
  switch (phase) {
    case "loading":
      return { phase: "loading" };
    case "ready":
      return { phase: "ready", data: [SAMPLE], notes: [] };
    case "partial":
      return {
        phase: "ready",
        data: [SAMPLE],
        notes: [{ tone: "warning", text: "另有 37 封未加载（示例）" }],
      };
    case "empty":
      return { phase: "empty", data: [], notes: [] };
    case "error":
      return {
        phase: "error",
        title: t.list.loadFailed,
        detail: "连不上边车：Connection refused（示例）",
        cause: "transport",
        retryable: true,
      };
    case "offline":
      return { phase: "offline", detail: "navigator.onLine = false（示例）" };
    case "unavailable":
      return {
        phase: "unavailable",
        reason: "no-account",
        title: t.onboarding.title,
        detail: "还没有账号，所以列表没有数据源（示例）",
      };
  }
}

export function StatesGallery(): ReactNode {
  const phases: Case[] = [
    "loading",
    "empty",
    "ready",
    "partial",
    "error",
    "offline",
    "unavailable",
  ];
  const labels: Record<string, string> = {
    loading: t.states.loading,
    empty: t.states.empty,
    ready: t.states.ready,
    partial: t.states.partial,
    error: t.states.error,
    offline: t.states.offline,
    unavailable: t.states.unavailable,
    unknown: t.states.unknown,
  };

  return (
    <div className="gallery">
      <h1>
        {t.states.title} <span className="badge demo">{t.app.demoBadge}</span>
      </h1>
      <p className="lede">{t.states.detail}</p>
      <div className="gallery-grid">
        {phases.map((phase) => (
          <Card key={phase} title={labels[phase] ?? phase}>
            <AsyncSurface
              outcome={rowOutcome(phase)}
              onRetry={() => undefined}
              onRefresh={() => undefined}
              empty={{ title: t.list.empty.inbox[0], detail: t.list.empty.inbox[1] }}
              compact
            >
              {(rows) => (
                <div className="rows" style={{ width: "100%" }}>
                  {rows.map((row) => (
                    <div className="mail-row" key={row.remoteId}>
                      <span className="marker on" />
                      <span className="mail-main">
                        <span className="mail-line1">
                          <span className="mail-subject">{row.subject}</span>
                        </span>
                        <span className="mail-sender">{row.fromAddress}</span>
                      </span>
                    </div>
                  ))}
                </div>
              )}
            </AsyncSurface>
          </Card>
        ))}
        <Card title={labels.unknown}>
          <div className="surface compact" style={{ alignItems: "flex-start" }}>
            <TriBadge label="archive" gate={undefined} />
            <TriBadge label="delete" gate={false} />
            <TriBadge label="purge" gate={true} />
            <div className="surface-detail">{t.six.notProbedHint}</div>
            <div className="surface-detail">totalCount 缺失 → 显示 “—” 而不是 0</div>
          </div>
        </Card>
        <Card title="每个透镜的空态文案（S2）">
          <div className="surface compact" style={{ alignItems: "flex-start", gap: 2 }}>
            {(["inbox", "unread", "pinned", "archived", "sent", "trash"] as const).map((lens) => (
              <div key={lens} className="surface-detail" style={{ textAlign: "left" }}>
                <strong>{lens}</strong> → {t.list.empty[lens][0]}：{t.list.empty[lens][1]}
              </div>
            ))}
          </div>
        </Card>
        <Card title="HTML 沙箱自检（隐私）">
          <div style={{ width: "100%", padding: "var(--sp-sm)" }}>
            <div className="surface-detail" style={{ textAlign: "left", marginBottom: "var(--sp-sm)" }}>
              下面这张卡一片区域内：cid 内联图应当显示；远程图片、脚本一律应当被 CSP 拦掉（DevTools 的 Network
              里不应出现 example.com 的请求）。
            </div>
            <HtmlFrame
              html={SANDBOX_HTML}
              images={{ demo: PIXEL_PNG_B64 }}
              mimeByCid={{ demo: "image/png" }}
              title="HTML 沙箱自检"
            />
          </div>
        </Card>
        <Card title="部分成功：横幅叠在数据上">
          <div style={{ width: "100%" }}>
            <Banner tone="warning" title={t.six.partial} detail="3 张内联图没取到（示例）" />
            <div className="surface compact">
              <div className="surface-detail">数据照常显示：失败的是图片，不是正文。</div>
            </div>
          </div>
        </Card>
      </div>
    </div>
  );
}

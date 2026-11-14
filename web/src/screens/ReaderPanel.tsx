/**
 * The reading pane (MessageDetailView.swift, 1445 lines in v3 — M1 slice).
 *
 * Read path, exactly the order v3 uses (MessageDetailView.swift:930-993):
 *   1. GET /body                                    (always)
 *   2. GET /inline-images                           (only when the body carries
 *                                                    inline, image-typed parts)
 *   3. POST /read                                   (dwell; DISABLED in M1 —
 *                                                    see core/config.ts)
 * Steps 1 and 2 are independent: the text is readable while images are still
 * arriving, and a failed image must never blank the message. When some images
 * fail the pane says so in a second line (that is the reader's "partial success"
 * state, v3: MessageDetailView.swift:995-1011).
 *
 * Every write verb is rendered disabled with "M2 开放" instead of hidden: a
 * missing button is indistinguishable from a missing feature, and M1's promise
 * is "you can read everything, you cannot change anything".
 */
import { useEffect, useMemo, useState, type ReactNode } from "react";
import type { AiStatus, Attachment, ConnectedAccount, InlineImagesResponse, MessageBody, MessageSummary } from "../core/types";
import { apiCall, downloadFile, type ApiFailureCode } from "../core/api";
import { attachmentPath, downloadName, formatSize, isDownloadable, isInlineImage } from "../core/attachments";
import { COMMON_UNAVAILABLE, describeHttpFailure } from "../core/errors";
import { useApiOutcome } from "../core/hooks";
import type { SendOriginal } from "../core/send";
import { AsyncSurface } from "../ui/AsyncSurface";
import { TriBadge, Banner } from "../ui/atoms";
import { formatWhen } from "../ui/format";
import type { WriteBridge } from "../core/uiBridge";
import { HtmlFrame } from "./HtmlFrame";
import { UnsubscribeStrip } from "../ui/UnsubscribeStrip";
import { t } from "../l10n/zh";

function mimeMapOf(attachments: Attachment[]): Record<string, string> {  const map: Record<string, string> = {};
  for (const attachment of attachments) {
    const cid = attachment.contentId?.trim().toLowerCase();
    if (cid) map[cid] = attachment.mimeType;
  }
  return map;
}

/**
 * What to say when the download never reached the server (or its bytes never
 * reached the disk). The shell's messages are English diagnostics; these are
 * the user's copy. `bad-path` / `bad-request` are front-end bugs, and there
 * the diagnostic itself is the truth worth showing.
 */
function downloadFailureText(code: ApiFailureCode | "save", message: string): string {
  switch (code) {
    case "not-ready":
      return t.reader.downloadNotReady;
    case "timeout":
      return t.reader.downloadTimeout;
    case "transport":
      return t.reader.downloadTransport;
    case "save":
      return t.reader.downloadSaveFailed(message);
    default:
      return message;
  }
}

function SummaryPanel(props: { remoteId: string; accountId: string }): ReactNode {  const [opened, setOpened] = useState(false);
  const summary = useApiOutcome<MessageSummary>({
    deps: [props.remoteId, opened],
    enabled: opened,
    load: () =>
      apiCall<MessageSummary>({
        method: "GET",
        path: "/api/messages/" + encodeURIComponent(props.remoteId) + "/summary",
        query: { accountId: props.accountId },
      }),
    translate: {
      errorTitle: t.reader.summary,
      unavailableCodes: COMMON_UNAVAILABLE,
      describeCode: describeHttpFailure,
    },
  });


  return (
    <div style={{ marginTop: "var(--sp-md)" }}>
      <button className="btn" onClick={() => setOpened((v) => !v)} aria-expanded={opened}>
        {t.reader.summary}
      </button>
      {opened ? (
        <div style={{ marginTop: "var(--sp-sm)" }}>
          <AsyncSurface
            outcome={summary.outcome}
            onRetry={summary.refresh}
            empty={{ title: t.reader.summaryTitle, detail: "" }}
            loadingLabel={t.six.loading}
            compact
          >
            {(value) => (
              <div>
                <p style={{ margin: "0 0 var(--sp-sm)" }}>{value.summary}</p>
                {value.actionItems.length > 0 ? (
                  <>
                    <div className="surface-detail">{t.reader.summaryActions}</div>
                    <ul style={{ margin: "var(--sp-xs) 0 0", paddingLeft: "1.2em" }}>
                      {value.actionItems.map((item, index) => (
                        <li key={String(index)}>{item}</li>
                      ))}
                    </ul>
                  </>
                ) : null}
              </div>
            )}
          </AsyncSurface>
        </div>
      ) : null}
    </div>
  );
}

export interface ReaderPanelProps {
  remoteId: string | null;
  account: ConnectedAccount;
  aiStatus?: AiStatus;
  writes: WriteBridge;
  onPurge: (remoteId: string) => void;
  onOpenHistory: () => void;
  onClose: () => void;
  /** Reply to the open message. */
  onReply: (original: SendOriginal) => void;
  /** Forward the open message, original included. */
  onForward: (original: SendOriginal) => void;
  /**
   * Reports what "the open message" is, so the window's shortcuts can reply
   * to it. `undefined` when there is nothing to reply to.
   */
  onReplyTarget: (original: SendOriginal | undefined) => void;
  /** One line of feedback for the toast (a download has a visible result). */
  onToast: (text: string) => void;
  /** RFC 8058 one-click for the open mail; the caller owns confirm + errors. */
  onUnsubscribe: (remoteId: string) => void;
}

export function ReaderPanel(props: ReaderPanelProps): ReactNode {
  const { remoteId, account } = props;
  const [images, setImages] = useState<Record<string, string>>({});
  const [imagesFailed, setImagesFailed] = useState(0);
  const [imagesLoading, setImagesLoading] = useState(false);
  /** The attachment id being saved; one at a time (each save fetches the message). */
  const [downloadingId, setDownloadingId] = useState<string | null>(null);

  const body = useApiOutcome<MessageBody>({
    deps: [remoteId, account.id],
    enabled: remoteId !== null,
    load: () =>
      apiCall<MessageBody>({
        method: "GET",
        path: "/api/messages/" + encodeURIComponent(remoteId ?? "") + "/body",
        query: { accountId: account.id },
      }),
    translate: {
      errorTitle: t.reader.loadFailed,
      describeCode: describeHttpFailure,
      unavailableCodes: {
        ...COMMON_UNAVAILABLE,
        "provider-auth-failed": {
          reason: "capability",
          title: "邮箱授权过期了",
          detail: "服务端返回 401 provider-auth-failed：需要重新连接这个邮箱。",
        },
        "message-gone": {
          reason: "capability",
          title: t.reader.gone,
          detail: "410 是确定的结论：重试不会把它找回来。",
        },
      },
    },
  });

  const bodyData = body.outcome.phase === "ready" ? body.outcome.data : undefined;

  /**
   * What "reply to this message" means: the fields the composer prefills.
   *
   * Memoised on the body, not rebuilt per render - the window's shortcuts ask
   * for it, and a fresh object every render would report a new "current
   * message" forever.
   */
  const replyTarget = useMemo<SendOriginal | undefined>(
    () =>
      bodyData
        ? {
            remoteId: bodyData.remoteId,
            fromAddress: bodyData.fromAddress,
            fromName: bodyData.fromName,
            subject: bodyData.subject,
            receivedAt: bodyData.receivedAt,
            when: formatWhen(bodyData.receivedAt),
            text: bodyData.text,
          }
        : undefined,
    [bodyData],
  );

  useEffect(() => {
    props.onReplyTarget(replyTarget);
  }, [replyTarget, props.onReplyTarget]);

  // Images are a separate, fire-and-forget request: the text must never wait on
  // them, and a partial failure must not blank the message.
  useEffect(() => {
    setImages({});
    setImagesFailed(0);
    const data = bodyData;
    if (!data) return;
    const wanted = data.attachments.filter(isInlineImage);
    if (wanted.length === 0) return;
    let cancelled = false;
    setImagesLoading(true);
    void (async () => {
      const result = await apiCall<InlineImagesResponse>({
        method: "GET",
        path: "/api/messages/" + encodeURIComponent(data.remoteId) + "/inline-images",
        query: { accountId: account.id },
      });
      if (cancelled) return;
      if (result.kind === "ok") {
        setImages(result.data.images);
        const missing = wanted.filter((attachment) => {
          const cid = attachment.contentId?.trim().toLowerCase();
          return !cid || !(cid in result.data.images);
        }).length;
        setImagesFailed(missing);
      } else {
        setImagesFailed(wanted.length);
      }
      setImagesLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [bodyData, account.id]);

  /**
   * Save one attachment.
   *
   * Bytes cannot ride the JSON proxy, so this goes through `downloadFile`: the
   * shell writes the file beside the store and reveals it in Finder, the
   * browser build hands the Blob to the browser. It never *opens* the file —
   * an attachment is someone else's file, and clicking a chip is not consent
   * to run it.
   */
  async function download(attachment: Attachment): Promise<void> {
    if (remoteId === null || downloadingId !== null) return;
    setDownloadingId(attachment.id);
    try {
      const name = downloadName(attachment);
      const result = await downloadFile({
        path: attachmentPath(remoteId, attachment.id),
        query: { accountId: account.id },
        filename: name,
      });
      if (result.kind === "saved") {
        props.onToast(result.path ? t.reader.downloaded(name) : t.reader.downloadStarted(name));
      } else if (result.kind === "http") {
        props.onToast(t.reader.downloadFailed(describeHttpFailure(result.code, result.status)));
      } else {
        props.onToast(t.reader.downloadFailed(downloadFailureText(result.code, result.message)));
      }
    } finally {
      setDownloadingId(null);
    }
  }

  if (remoteId === null) {
    return (
      <div className="pane">
        <div className="pane-body">
          <div className="surface" role="status">
            <div className="surface-title">{t.reader.emptyTitle}</div>
            <div className="surface-detail">{t.reader.emptyDetail}</div>
          </div>
        </div>
      </div>
    );
  }

  const mimeByCid = bodyData ? mimeMapOf(bodyData.attachments) : {};

  return (
    <div className="pane">
      <div className="pane-head">
        <span className="surface-title">{t.reader.title}</span>
        <span className="badge">{account.email}</span>
        {props.aiStatus && !props.aiStatus.configured ? <span className="badge">{t.reader.aiNotConfigured}</span> : null}
        <span className="spacer" />
        <button className="btn" onClick={props.onClose}>
          {t.six.dismiss}
        </button>
      </div>
      <div className="pane-body">
        <div className="reader">
          {bodyData ? (
            <div className="reader-head">
              <h2 className="reader-subject">{bodyData.subject ?? "(无主题)"}</h2>
              <div className="reader-meta">
                <span>
                  {t.reader.from}: {bodyData.fromName ? bodyData.fromName + " <" + bodyData.fromAddress + ">" : bodyData.fromAddress}
                </span>
                <span>
                  {t.reader.to}: {bodyData.to.join(", ") || bodyData.toAddress || "—"}
                </span>
                {bodyData.cc.length > 0 ? <span>{t.reader.cc}: {bodyData.cc.join(", ")}</span> : null}
                {bodyData.attachments.filter(isDownloadable).length > 0 ? (
                  <span>{t.reader.attachments(bodyData.attachments.filter(isDownloadable).length)}</span>
                ) : null}
              </div>
              <UnsubscribeStrip
                links={bodyData.unsubscribeLinks}
                onOneClick={
                  remoteId ? () => props.onUnsubscribe(remoteId) : undefined
                }
              />
            </div>
          ) : null}

          <ReaderActionBar
            remoteId={remoteId}
            account={account}
            writes={props.writes}
            onPurge={() => props.onPurge(remoteId)}
            onOpenHistory={props.onOpenHistory}
            imagesLoading={imagesLoading}
            imagesFailed={imagesFailed}
            replyTarget={replyTarget}
            onReply={props.onReply}
            onForward={props.onForward}
          />

          <div className="reader-body">
            <div className="reader-body-inner">
              <AsyncSurface
                outcome={body.outcome}
                onRetry={body.refresh}
                empty={{ title: t.reader.loadFailed, detail: "" }}
                loadingLabel={t.reader.loading}
              >
                {(data) => (
                  <>
                    <p className="surface-detail" style={{ marginTop: 0 }}>
                      {data.html ? t.reader.htmlNote : t.reader.plainFallback}
                    </p>
                    {data.html ? (
                      <HtmlFrame
                        html={data.html}
                        images={images}
                        mimeByCid={mimeByCid}
                        title={t.reader.htmlNote}
                      />
                    ) : (
                      <div className="plain-body">{data.text}</div>
                    )}
                    {data.hasMore ? <Banner tone="info" title={t.six.partial} detail="hasMore=true：正文被截断（服务端分页）。" /> : null}
                    {data.attachments.filter(isDownloadable).length > 0 ? (
                      <div className="attach-list">
                        {data.attachments
                          .filter(isDownloadable)
                          .map((a) => {
                            const size = formatSize(a.size);
                            const busy = downloadingId === a.id;
                            // A part with no id has no route to fetch it from;
                            // it is listed, but not offered.
                            const offered = isDownloadable(a);
                            const title = !offered
                              ? t.reader.downloadNoId
                              : downloadingId !== null && !busy
                                ? t.reader.downloadBusy
                                : t.reader.downloadHint(downloadName(a));
                            return (
                              <button
                                key={a.id}
                                className="chip"
                                disabled={!offered || downloadingId !== null}
                                title={title}
                                onClick={() => void download(a)}
                              >
                                {busy ? "⏳" : "📎"} {a.filename ?? a.id}
                                {size ? " · " + size : ""} · {a.mimeType}
                              </button>
                            );
                          })}
                      </div>
                    ) : null}
                    <SummaryPanel remoteId={data.remoteId} accountId={account.id} />
                    <div style={{ marginTop: "var(--sp-md)", display: "flex", gap: "var(--sp-xs)", flexWrap: "wrap" }}>
                      <span className="surface-detail">{t.reader.capabilities}</span>
                      <TriBadge label="archive" gate={account.capabilities.archiveFolder} />
                      <TriBadge label="delete" gate={account.capabilities.trashFolder} />
                      <TriBadge label="purge" gate={account.capabilities.uidplus} />
                      <TriBadge label="sent" gate={account.capabilities.sentFolder} />
                    </div>
                  </>
                )}
              </AsyncSurface>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
/**
 * The reader's action bar.
 *
 * v3 keeps it *inside* the reading pane rather than in the window toolbar, and
 * says why: toolbar items that appear/disappear when a detail is pushed tripped
 * an AppKit crash (MessageDetailView.swift:335-344). The Web has no such crash,
 * but it keeps the placement because it is also the better UX: the verbs sit
 * next to the message they act on.
 *
 * Capability rule: a settled false disables the button *and* explains itself in
 * the title; nil (not probed) leaves it enabled and lets the server's 409 be the
 * authority (MailCapabilities.swift:121-156).
 */
function ReaderActionBar(props: {
  remoteId: string;
  account: ConnectedAccount;
  writes: WriteBridge;
  onPurge: () => void;
  onOpenHistory: () => void;
  imagesLoading: boolean;
  imagesFailed: number;
  replyTarget?: SendOriginal;
  onReply: (original: SendOriginal) => void;
  onForward: (original: SendOriginal) => void;
}): ReactNode {
  const { account, writes, remoteId } = props;
  const archived = account.capabilities.archiveFolder;
  const trash = account.capabilities.trashFolder;
  void archived;
  void trash;
  const busy = writes.busy;

  return (
    <div className="reader-toolbar">
      <button
        className="btn"
        disabled={busy || !props.replyTarget}
        title={props.replyTarget ? t.compose.replyTitle : t.reader.replyNeedsBody}
        onClick={() => {
          if (props.replyTarget) props.onReply(props.replyTarget);
        }}
      >
        ↩ {t.compose.replyTitle}
      </button>
      <button
        className="btn"
        disabled={busy || !props.replyTarget}
        title={props.replyTarget ? t.compose.forwardTitle : t.reader.replyNeedsBody}
        onClick={() => {
          if (props.replyTarget) props.onForward(props.replyTarget);
        }}
      >
        ⇉ {t.compose.forwardTitle}
      </button>
      <span className="toolbar-divider" aria-hidden="true" />
      <button
        className="btn"
        disabled={busy}
        title={t.m2.actions.pin}
        onClick={() => writes.row("pin", remoteId)}
      >
        ⌖ {t.m2.actions.pin}
      </button>
      <button
        className="btn"
        disabled={busy}
        title={t.m2.actions.markRead}
        onClick={() => writes.row("markRead", remoteId)}
      >
        ◉ {t.m2.actions.markRead}
      </button>
      <span className="toolbar-divider" aria-hidden="true" />
      <button
        className="btn"
        disabled={busy || !writes.canArchive}
        title={writes.canArchive ? t.m2.actions.archive : writes.archiveHint}
        onClick={() => writes.row("archive", remoteId)}
      >
        ⤓ {t.m2.actions.archive}
      </button>
      <button
        className="btn"
        disabled={busy || !writes.canDelete}
        title={writes.canDelete ? t.m2.actions.delete : writes.deleteHint}
        onClick={() => writes.row("delete", remoteId)}
      >
        ⌫ {t.m2.actions.delete}
      </button>
      <button
        className="btn danger"
        disabled={busy || !writes.canPurge}
        title={writes.canPurge ? t.m2.actions.purge : writes.purgeHint}
        onClick={props.onPurge}
      >
        ⨯ {t.m2.actions.purge}
      </button>
      <span className="spacer" />
      {props.imagesLoading ? <span className="chip">{t.reader.inlineLoading}</span> : null}
      {props.imagesFailed > 0 ? (
        <span className="chip warn">{t.reader.inlinePartial(props.imagesFailed)}</span>
      ) : null}
      <button className="btn" onClick={props.onOpenHistory} title={t.m2.actions.history}>
        {t.m2.actions.history}
      </button>
    </div>
  );
}

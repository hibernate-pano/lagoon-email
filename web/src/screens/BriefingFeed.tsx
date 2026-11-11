/**
 * The Briefing feed (BriefingFeedView.swift, 2432 lines in v3 — M2 slice).
 *
 * What is kept from v3 because it is the product:
 *   - five fixed groups in that order, emoji + live count, collapsible, and
 *     subscription noise collapsed by default (Briefing.swift:8-30);
 *   - the third line is the classifier's *reason*, not the snippet;
 *   - the inline advice strip on the row the user is already looking at;
 *   - the two boundary rows at the bottom — "另有 N 封未纳入简报" and "更早还有
 *     N 封未读" are real rows, not toasts, so they can be found again;
 *   - three different empty states (sync broken / first sync / inbox zero).
 *
 * M2 adds the row verbs and the same selection model as the raw list: the two
 * surfaces are two views of one mailbox, and a verb that exists on one must
 * exist on the other (constitution §2, "同一个动词，在两个表面必须都存在").
 */
import { useMemo, useState, type ReactNode } from "react";
import type { AdviceRecord, BriefingGroupId, BriefingResponse, SyncHealth } from "../core/types";
import type { Outcome } from "../core/async";
import type { WriteBridge } from "../core/uiBridge";
import { AsyncSurface } from "../ui/AsyncSurface";
import { AdviceStrip } from "../ui/AdviceStrip";
import { BulkBar } from "../ui/BulkBar";
import { MailRow } from "../ui/MailRow";
import { RowActions } from "../ui/RowActions";
import { t } from "../l10n/zh";

const GROUP_ORDER: BriefingGroupId[] = [
  "needsReply",
  "awaitingReply",
  "safeToArchive",
  "subscriptionNoise",
  "pinned",
];

const GROUP_EMOJI: Record<BriefingGroupId, string> = {
  needsReply: "🔴",
  awaitingReply: "⏳",
  safeToArchive: "🟢",
  subscriptionNoise: "🆕",
  pinned: "📌",
};

function groupLabel(group: BriefingGroupId): string {
  switch (group) {
    case "needsReply":
      return t.briefing.groupNeedsReply;
    case "awaitingReply":
      return t.briefing.groupAwaitingReply;
    case "safeToArchive":
      return t.briefing.groupSafeToArchive;
    case "subscriptionNoise":
      return t.briefing.groupSubscriptionNoise;
    case "pinned":
      return t.briefing.groupPinned;
  }
}

function reasonOf(reasonCode: string | null | undefined): string | null {
  if (!reasonCode) return null;
  const table = t.briefing.reasons as Record<string, string>;
  return table[reasonCode] ?? null;
}

export interface BriefingFeedProps {
  outcome: Outcome<BriefingResponse>;
  adviceByRemoteId: Record<string, AdviceRecord>;
  syncHealth?: SyncHealth;
  hasUserGroups: boolean;
  onRetry: () => void;
  onRefresh: () => void;
  openedId: string | null;
  cursor: string | null;
  selection: Set<string>;
  onRowSelect: (remoteId: string, event: { shiftKey: boolean; metaKey: boolean }) => void;
  writes: WriteBridge;
  onPurge: (remoteId: string) => void;
  /**
   * Carry out one suggestion from its row. The caller owns the write and the
   * decision recording; this surface only asks.
   */
  onAcceptAdvice?: (record: AdviceRecord) => void;
  onDismissAdvice?: (record: AdviceRecord) => void;
  adviceBusy?: boolean;
  onOpenHistory: () => void;
}

export function BriefingFeed(props: BriefingFeedProps): ReactNode {
  const [collapsed, setCollapsed] = useState<Set<BriefingGroupId>>(
    () => new Set<BriefingGroupId>(["subscriptionNoise"]),
  );

  const empty = useMemo(() => {
    const health = props.syncHealth;
    if (health && health.status !== "ok") {
      return {
        title: t.briefing.syncBroken,
        detail: t.briefing.syncBrokenHint + " " + (health.lastError ?? ""),
      };
    }
    if (health && !health.lastSyncAt) {
      return { title: t.briefing.syncingFirst, detail: t.briefing.syncingFirstCount(0) };
    }
    return { title: t.briefing.inboxZero, detail: t.briefing.inboxZeroHint };
  }, [props.syncHealth]);

  const toggle = (group: BriefingGroupId) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (next.has(group)) next.delete(group);
      else next.add(group);
      return next;
    });
  };

  return (
    <div className="pane">
      <div className="pane-head">
        <span className="surface-title">{t.sidebar.briefing}</span>
        {props.hasUserGroups ? <span className="badge">{t.sidebar.myGroups}</span> : null}
        <span className="spacer" />
        <button className="btn" onClick={props.onOpenHistory} title={t.m2.actions.history}>
          {t.m2.actions.history}
        </button>
        <button className="btn" onClick={props.onRefresh}>
          {t.six.refresh}
        </button>
      </div>
      <div className="pane-body">
        <AsyncSurface
          outcome={props.outcome}
          onRetry={props.onRetry}
          onRefresh={props.onRefresh}
          empty={empty}
          loadingLabel={t.briefing.loading}
        >
          {(data) => (
            <div className="rows" role="listbox" aria-multiselectable="true" aria-label={t.sidebar.briefing}>
              {GROUP_ORDER.map((group) => {
                const items = data.items.filter((item) => item.group === group);
                if (items.length === 0) return null;
                const isCollapsed = collapsed.has(group);
                return (
                  <section key={group}>
                    <button
                      type="button"
                      className="group-head"
                      aria-expanded={!isCollapsed}
                      onClick={() => toggle(group)}
                    >
                      <span aria-hidden="true">{isCollapsed ? "▸" : "▾"}</span>
                      <span>
                        {GROUP_EMOJI[group]} {groupLabel(group)}
                      </span>
                      <span className="spacer" />
                      <span>{items.length}</span>
                    </button>
                    {isCollapsed
                      ? null
                      : items.map((item) => {
                          const advice = props.adviceByRemoteId[item.message.remoteId];
                          const reason = reasonOf(item.reasonCode);
                          return (
                            <MailRow
                              key={item.message.remoteId}
                              message={item.message}
                              variant="briefing"
                              thirdLine={reason ?? item.message.snippet}
                              advice={
                                advice && advice.advice.action !== "nothing" ? (
                                  <AdviceStrip
                                    record={advice}
                                    busy={props.adviceBusy}
                                    onAccept={
                                      props.onAcceptAdvice &&
                                      (() => props.onAcceptAdvice?.(advice))
                                    }
                                    onDismiss={
                                      props.onDismissAdvice &&
                                      (() => props.onDismissAdvice?.(advice))
                                    }
                                  />
                                ) : null
                              }
                              opened={props.openedId === item.message.remoteId}
                              isCursor={props.cursor === item.message.remoteId}
                              checked={props.selection.has(item.message.remoteId)}
                              onSelect={(event) => props.onRowSelect(item.message.remoteId, event)}
                              actions={
                                <RowActions
                                  message={item.message}
                                  lens="briefing"
                                  writes={props.writes}
                                  onPurge={() => props.onPurge(item.message.remoteId)}
                                />
                              }
                            />
                          );
                        })}
                  </section>
                );
              })}
              {data.omittedCount && data.omittedCount > 0 ? (
                <div className="surface compact" role="status">
                  <div className="surface-detail">{t.briefing.omitted(data.omittedCount)}</div>
                </div>
              ) : null}
              {data.backlogCount && data.backlogCount > 0 ? (
                <div className="surface compact" role="status">
                  <div className="surface-detail">{t.briefing.backlog(data.backlogCount)}</div>
                </div>
              ) : null}
            </div>
          )}
        </AsyncSurface>
      </div>
      <BulkBar
        count={props.selection.size}
        canArchive={props.writes.canArchive}
        canDelete={props.writes.canDelete}
        archiveHint={props.writes.archiveHint}
        deleteHint={props.writes.deleteHint}
        busy={props.writes.busy}
        onArchive={() => props.writes.bulk("archive")}
        onDelete={() => props.writes.bulk("delete")}
        onClear={props.writes.clearSelection}
      />
    </div>
  );
}

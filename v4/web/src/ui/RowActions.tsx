/**
 * Per-row verbs, shown on hover/focus — the Web stand-in for v3's swipe actions
 * and right-click menu. A mail client has to offer them from the row itself.
 *
 * Every button carries its reason when disabled: the v3 audit's repeated finding
 * was that a live button that does nothing, or a dead button with no
 * explanation, is worse than no button. The title attribute is that explanation.
 */
import type { ReactNode } from "react";
import type { WriteBridge } from "../core/uiBridge";
import type { LensId } from "../core/router";
import type { MessageHeader } from "../core/types";
import { t } from "../l10n/zh";

export interface RowActionsProps {
  message: MessageHeader;
  lens: LensId | "briefing";
  writes: WriteBridge;
  onPurge: () => void;
}

export function RowActions(props: RowActionsProps): ReactNode {
  const { message, lens, writes } = props;
  const disabled = writes.busy;
  return (
    <span className="row-actions" onClick={(event) => event.stopPropagation()}>
      <button
        type="button"
        className="row-action"
        title={message.isPinned ? t.m2.actions.unpin : t.m2.actions.pin}
        aria-label={message.isPinned ? t.m2.actions.unpin : t.m2.actions.pin}
        disabled={disabled}
        onClick={() => writes.row(message.isPinned ? "unpin" : "pin", message.remoteId)}
      >
        ⌖
      </button>
      <button
        type="button"
        className="row-action"
        title={message.isRead ? t.m2.actions.markUnread : t.m2.actions.markRead}
        aria-label={message.isRead ? t.m2.actions.markUnread : t.m2.actions.markRead}
        disabled={disabled}
        onClick={() => writes.row(message.isRead ? "markUnread" : "markRead", message.remoteId)}
      >
        {message.isRead ? "◌" : "◉"}
      </button>

      {lens === "trash" ? (
        <>
          <button
            type="button"
            className="row-action"
            title={t.m2.actions.restore}
            aria-label={t.m2.actions.restore}
            disabled={disabled}
            onClick={() => writes.row("restore", message.remoteId)}
          >
            ↺
          </button>
          <button
            type="button"
            className="row-action danger"
            title={writes.canPurge ? t.m2.actions.purge : writes.purgeHint}
            aria-label={t.m2.actions.purge}
            disabled={disabled || !writes.canPurge}
            onClick={props.onPurge}
          >
            ⨯
          </button>
        </>
      ) : lens === "archived" ? (
        <button
          type="button"
          className="row-action"
          title={t.m2.actions.unarchive}
          aria-label={t.m2.actions.unarchive}
          disabled={disabled || !writes.canArchive}
          onClick={() => writes.row("unarchive", message.remoteId)}
        >
          ⤒
        </button>
      ) : lens === "sent" ? null : (
        <button
          type="button"
          className="row-action"
          title={writes.canArchive ? t.m2.actions.archive : writes.archiveHint}
          aria-label={t.m2.actions.archive}
          disabled={disabled || !writes.canArchive}
          onClick={() => writes.row("archive", message.remoteId)}
        >
          ⤓
        </button>
      )}

      {lens !== "trash" && lens !== "sent" ? (
        <button
          type="button"
          className="row-action danger"
          title={writes.canDelete ? t.m2.actions.delete : writes.deleteHint}
          aria-label={t.m2.actions.delete}
          disabled={disabled || !writes.canDelete}
          onClick={() => writes.row("delete", message.remoteId)}
        >
          ⌫
        </button>
      ) : null}
    </span>
  );
}

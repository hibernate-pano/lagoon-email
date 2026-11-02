/**
 * One mail row. The two surfaces differ by *what the third line is*, not by
 * typography (LagoonTypography.swift:8-20): the Briefing shows the classifier's
 * reason line and a 28pt avatar, the raw list shows the snippet and a 7pt unread
 * dot. v3 shipped six copies of "a mail row" and the audit called it the visible
 * bug; here there is one component with a variant switch.
 *
 * M2 adds two things a write-capable row needs: a selected state that can be
 * independent of the cursor (multi-select), and a slot for the row's own verbs.
 */
import type { ReactNode } from "react";
import type { MessageHeader } from "../core/types";
import { Avatar } from "./atoms";
import { displayNameOf, formatRowTimestamp } from "./format";

export interface MailRowProps {
  message: MessageHeader;
  variant: "briefing" | "list";
  /** Third line: reason (briefing) or snippet (list). */
  thirdLine?: string | null;
  /** Advice strip, briefing only. */
  advice?: ReactNode;
  /** Row verbs (M2). Hidden until hover/focus by CSS. */
  actions?: ReactNode;
  /** The reader's current message. */
  opened: boolean;
  /** Part of the multi-selection. */
  checked: boolean;
  /** The keyboard cursor: the row j/k currently points at. */
  isCursor?: boolean;
  onSelect: (event: { shiftKey: boolean; metaKey: boolean }) => void;
}

export function MailRow(props: MailRowProps): ReactNode {
  const { message, variant } = props;
  const unread = !message.isRead;
  const className = [
    "mail-row",
    unread ? "unread" : "",
    props.checked ? "checked" : "",
    props.opened ? "opened" : "",
    props.isCursor ? "cursor" : "",
    message.isPinned ? "pinned" : "",
  ]
    .filter(Boolean)
    .join(" ");

  // Roving tabindex: Tab lands on the row the keyboard cursor is on, not on
  // every row (which would make Tab useless in a long list).
  return (
    <div
      className={className}
      role="option"
      aria-selected={props.checked || props.opened}
      aria-current={props.isCursor ? "true" : undefined}
      tabIndex={props.isCursor ? 0 : -1}
      onClick={(event) => props.onSelect({ shiftKey: event.shiftKey, metaKey: event.metaKey || event.ctrlKey })}
      onKeyDown={(event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          props.onSelect({ shiftKey: event.shiftKey, metaKey: event.metaKey || event.ctrlKey });
        }
      }}
    >
      <span className="marker-col">
        {props.checked ? (
          <span className="tick" aria-hidden="true">
            ✓
          </span>
        ) : variant === "briefing" ? (
          <Avatar email={message.fromAddress} name={message.fromName} />
        ) : (
          <span className={"marker" + (unread ? " on" : "")} aria-hidden="true" />
        )}
      </span>
      <span className="mail-main">
        <span className="mail-line1">
          <span className="mail-subject">{message.subject ?? "(无主题)"}</span>
          {message.isPinned ? (
            <span className="pin-mark" title="已置顶" aria-label="已置顶">
              ⌖
            </span>
          ) : null}
          <span className="mail-time">{formatRowTimestamp(message.receivedAt)}</span>
        </span>
        <span className="mail-sender">{displayNameOf(message)}</span>
        {props.thirdLine ? <span className="mail-third">{props.thirdLine}</span> : null}
        {props.advice}
      </span>
      {props.actions ? <span className="row-actions-slot">{props.actions}</span> : null}
    </div>
  );
}

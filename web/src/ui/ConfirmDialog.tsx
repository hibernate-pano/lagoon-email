/**
 * A blocking confirm for the two irreversible verbs in the product.
 *
 * v3 used .alert for purge and for empty-trash, and said why: "a sheet reads as
 * a settings panel and gets dismissed reflexively, whereas an alert has to be
 * answered" (MessageListView.swift:695-699). The Web equivalent is this dialog,
 * not window.confirm (which cannot state the consequence in the product's voice
 * and cannot be styled).
 */
import { useEffect, useRef, type ReactNode } from "react";
import { t } from "../l10n/zh";

export interface ConfirmRequest {
  title: string;
  message: string;
  confirmLabel?: string;
  destructive?: boolean;
  onConfirm: () => void;
}

export function ConfirmDialog(props: {
  request: ConfirmRequest | null;
  busy: boolean;
  onCancel: () => void;
}): ReactNode {
  const confirmRef = useRef<HTMLButtonElement | null>(null);

  useEffect(() => {
    if (props.request) confirmRef.current?.focus();
  }, [props.request]);

  if (!props.request) return null;
  const request = props.request;

  return (
    <div
      className="scrim"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) props.onCancel();
      }}
    >
      <div
        className="dialog"
        role="alertdialog"
        aria-modal="true"
        aria-label={request.title}
        onKeyDown={(event) => {
          if (event.key === "Escape") {
            // Escape belongs to the dialog that is on top. Without this the
            // native event keeps bubbling to the window handler and cancels
            // whatever the dialog was guarding - here, it would close the
            // composer and destroy the draft the confirmation exists to save.
            event.stopPropagation();
            event.preventDefault();
            props.onCancel();
          }
        }}
      >
        <h2>{request.title}</h2>
        <p>{request.message}</p>
        <div className="dialog-actions">
          <button className="btn" onClick={props.onCancel} disabled={props.busy}>
            {t.m2.confirm.cancel}
          </button>
          <button
            ref={confirmRef}
            className={"btn " + (request.destructive ? "danger" : "primary")}
            onClick={() => request.onConfirm()}
            disabled={props.busy}
          >
            {props.busy ? t.m2.confirm.busy : request.confirmLabel ?? t.m2.confirm.confirm}
          </button>
        </div>
      </div>
    </div>
  );
}

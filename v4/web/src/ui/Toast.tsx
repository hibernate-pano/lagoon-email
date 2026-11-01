/**
 * The undo toast (v3: UndoController.swift:7-63, toast at the window's bottom).
 *
 * Two behaviours copied from v3 because both were bugs once:
 *   - the countdown pauses while the pointer is over the toast, so a toast that
 *     a user is reading does not vanish under the cursor;
 *   - a terminal action renders NO undo button instead of a disabled one —
 *     "a button that always errors teaches the user to ignore the toast"
 *     (UndoController.swift:69-72). Purge is exactly that case.
 */
import { useEffect, useRef, useState, type ReactNode } from "react";
import type { WriteFailure } from "../core/writes";
import { t } from "../l10n/zh";

export interface ToastState {
  id: number;
  text: string;
  /** Present only when the server gave us an actionId to reverse. */
  actionId?: number;
  /** Bulk writes return one actionId per message; undo goes through undo-bulk. */
  actionIds?: number[];
  failure?: WriteFailure;
}

export interface ToastProps {
  toast: ToastState | null;
  onUndo: () => void;
  onDismiss: () => void;
  windowMs: number;
}

export function Toast(props: ToastProps): ReactNode {
  const { toast, windowMs } = props;
  const [remaining, setRemaining] = useState(windowMs);
  const [hovered, setHovered] = useState(false);
  const startedAt = useRef(Date.now());

  useEffect(() => {
    if (!toast) return;
    startedAt.current = Date.now();
    setRemaining(windowMs);
    setHovered(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [toast?.id]);

  useEffect(() => {
    if (!toast) return;
    const tick = window.setInterval(() => {
      if (hovered) {
        // Paused: push the deadline forward by one tick instead of draining it.
        startedAt.current += 200;
        return;
      }
      const elapsed = Date.now() - startedAt.current;
      const left = windowMs - elapsed;
      setRemaining(left > 0 ? left : 0);
      if (left <= 0) props.onDismiss();
    }, 200);
    return () => window.clearInterval(tick);
  }, [toast, hovered, windowMs, props]);

  if (!toast) return null;
  const isFailure = toast.failure !== undefined;
  const undoable = (toast.actionId !== undefined || (toast.actionIds?.length ?? 0) > 0) && !isFailure;

  return (
    <div
      className={"toast" + (isFailure ? " failure" : "")}
      role="status"
      aria-live="polite"
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
    >
      <span className="toast-text">{toast.text}</span>
      {undoable ? (
        <button className="btn link toast-undo" onClick={props.onUndo} title={t.m2.toast.undoHint}>
          {t.m2.actions.undo} · ⌘Z
        </button>
      ) : null}
      <span className="toast-bar" aria-hidden="true">
        <span
          className="toast-bar-fill"
          style={{ width: String(Math.max(0, Math.min(100, (remaining / windowMs) * 100))) + "%" }}
        />
      </span>
      <button className="btn link toast-close" onClick={props.onDismiss} aria-label={t.six.dismiss}>
        ✕
      </button>
    </div>
  );
}

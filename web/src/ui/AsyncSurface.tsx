/**
 * The one component that renders a waiting surface (task-6 §4).
 *
 * Every panel in the app funnels through this, so a state cannot be forgotten
 * in one place and implemented in another — which is exactly how v3 ended up
 * with a failed search rendering as "nothing matched"
 * (Sources/Lagoon/Views/SearchSheet.swift:45, "A failed search is not an empty
 * one").
 *
 * Six states, plus the partial case (data AND a warning), plus the three
 * "unknowns" which live in TriBadge rather than here because they are not
 * states of a request.
 */
import type { ReactNode } from "react";
import type { Outcome, PartialNote } from "../core/async";
import { t } from "../l10n/zh";

export interface EmptyCopy {
  title: string;
  detail?: string;
}

export interface AsyncSurfaceProps<T> {
  outcome: Outcome<T>;
  /** Rows are already loaded: render them (a partial warning goes above them). */
  children: (data: T) => ReactNode;
  onRetry?: () => void;
  onRefresh?: () => void;
  empty: EmptyCopy;
  loadingLabel?: string;
  /** Extra action shown on unavailable/error, e.g. "连接账号". */
  action?: ReactNode;
  compact?: boolean;
}

function Notes({ notes }: { notes: PartialNote[] }) {
  if (notes.length === 0) return null;
  return (
    <div className="banner warning" role="status">
      <span className="banner-title">{t.six.partial}</span>
      <span>{notes.map((note) => note.text).join(" · ")}</span>
    </div>
  );
}

export function AsyncSurface<T>(props: AsyncSurfaceProps<T>): ReactNode {
  const { outcome, children, onRetry, onRefresh, empty, loadingLabel, action, compact } = props;
  const surfaceClass = compact ? "surface compact" : "surface";

  switch (outcome.phase) {
    case "loading":
      return (
        <div className={surfaceClass} aria-busy="true" aria-live="polite">
          <div className="spinner" aria-hidden="true" />
          <div className="surface-detail">{loadingLabel ?? t.six.loading}</div>
        </div>
      );

    case "offline":
      return (
        <div className={surfaceClass} role="status">
          <div className="surface-title">{t.six.offline}</div>
          <div className="surface-detail">{outcome.detail}</div>
          {onRetry ? (
            <div className="surface-actions">
              <button className="btn" onClick={onRetry}>
                {t.six.retry}
              </button>
            </div>
          ) : null}
        </div>
      );

    case "unavailable":
      return (
        <div className={surfaceClass} role="status">
          <div className="surface-title">{outcome.title}</div>
          {outcome.detail ? <div className="surface-detail">{outcome.detail}</div> : null}
          {action ? <div className="surface-actions">{action}</div> : null}
        </div>
      );

    case "error":
      return (
        <div className={surfaceClass} role="alert">
          <div className="surface-title">{outcome.title}</div>
          {outcome.detail ? <div className="surface-detail">{outcome.detail}</div> : null}
          <div className="surface-detail">
            {outcome.code ? (
              <span className="chip err">
                {t.six.serverCode}: {outcome.code}
                {outcome.status ? " (" + String(outcome.status) + ")" : ""}
              </span>
            ) : outcome.status ? (
              <span className="chip err">HTTP {outcome.status}</span>
            ) : null}
          </div>
          <div className="surface-actions">
            {outcome.retryable && onRetry ? (
              <button className="btn" onClick={onRetry}>
                {t.six.retry}
              </button>
            ) : null}
            {action}
          </div>
        </div>
      );

    case "empty":
      return (
        <div className={surfaceClass} role="status">
          <div className="surface-title">{empty.title}</div>
          {empty.detail ? <div className="surface-detail">{empty.detail}</div> : null}
          {onRefresh ? (
            <div className="surface-actions">
              <button className="btn" onClick={onRefresh}>
                {t.six.refresh}
              </button>
            </div>
          ) : null}
          <Notes notes={outcome.notes} />
        </div>
      );

    case "ready":
      return (
        <>
          <Notes notes={outcome.notes} />
          {children(outcome.data)}
        </>
      );
  }
}

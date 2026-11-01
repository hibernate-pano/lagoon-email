/**
 * The selection bar (v3: BulkActionBar.swift — it rises from the bottom because
 * the toolbar was already overflowing, and because the verbs belong next to the
 * rows they act on).
 *
 * Two rules from the v3 file that matter here:
 *   - a bar over a single row is noise: the row already has its own verbs, so the
 *     bar appears at count > 1 (BriefingSelection.bulkCount);
 *   - the count is a claim about blast radius, so when the server only processed
 *     part of it, the bar says so instead of letting the number stand.
 */
import type { ReactNode } from "react";
import { t } from "../l10n/zh";

export interface BulkBarProps {
  count: number;
  canArchive: boolean;
  canDelete: boolean;
  archiveHint?: string;
  deleteHint?: string;
  busy: boolean;
  onArchive: () => void;
  onDelete: () => void;
  onClear: () => void;
}

export function BulkBar(props: BulkBarProps): ReactNode {
  if (props.count <= 1) return null;
  return (
    <div className="bulk-bar" role="region" aria-label={t.m2.bulk.selected(props.count)}>
      <span className="bulk-count">{t.m2.bulk.selected(props.count)}</span>
      <button
        className="btn"
        onClick={props.onArchive}
        disabled={props.busy || !props.canArchive}
        title={props.canArchive ? undefined : props.archiveHint}
      >
        {t.m2.bulk.archive}
      </button>
      <button
        className="btn"
        onClick={props.onDelete}
        disabled={props.busy || !props.canDelete}
        title={props.canDelete ? undefined : props.deleteHint}
      >
        {t.m2.bulk.delete}
      </button>
      <span className="spacer" />
      <span className="bulk-hint">{t.m2.bulk.selectHint}</span>
      <button className="btn link" onClick={props.onClear}>
        {t.m2.bulk.clear}
      </button>
    </div>
  );
}

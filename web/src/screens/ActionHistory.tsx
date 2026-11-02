/**
 * The audit-log panel (GET /api/actions, paged with before=<actionId>).
 *
 * v3's ActionHistorySheet exists because the product writes to a mailbox and the
 * user has to be able to see what it did. In M2 it is also the only way to find
 * an action whose toast has gone: the undo window is 8 seconds, the log lasts
 * until the action expires.
 *
 * Paging uses the action id, not an offset: a new action arriving mid-page then
 * cannot duplicate or skip a row.
 */
import { useCallback, useEffect, useState, type ReactNode } from "react";
import type { ActionRecord } from "../core/types";
import { fetchActions, undoAction, type WriteFailure } from "../core/writes";
import { t } from "../l10n/zh";

const KIND_LABEL: Record<string, string> = {
  archive: t.m2.actions.archive,
  unarchive: t.m2.actions.unarchive,
  restore: t.m2.actions.restore,
  read: t.m2.actions.markRead,
  pin: t.m2.actions.pin,
  unpin: t.m2.actions.unpin,
  delete: t.m2.actions.delete,
  purge: t.m2.actions.purge,
  send: "发送",
  draft_create: "生成草稿",
  classify_override: "改分类",
  unsubscribe: "退订",
  undo: "撤销",
};

function kindLabel(kind: string): string {
  return KIND_LABEL[kind] ?? kind;
}

function isExpired(record: ActionRecord): boolean {
  if (!record.expiresAt) return false;
  const at = Date.parse(record.expiresAt);
  return Number.isFinite(at) ? at <= Date.now() : false;
}

export function ActionHistoryPanel(props: {
  accountId: string;
  onClose: () => void;
  onUndone: (text: string) => void;
  onFailure: (failure: WriteFailure) => void;
}): ReactNode {
  const [rows, setRows] = useState<ActionRecord[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(
    async (before?: number) => {
      setLoading(true);
      const result = await fetchActions(props.accountId, { limit: 50, before });
      setLoading(false);
      if (!("actions" in result)) {
        setError(result.message);
        return;
      }
      setError(null);
      setRows((current) => (before === undefined ? result.actions : [...current, ...result.actions]));
      setHasMore(result.hasMore === true);
    },
    [props.accountId],
  );

  useEffect(() => {
    void load();
  }, [load]);

  const undo = async (record: ActionRecord) => {
    setBusyId(record.id);
    const result = await undoAction(record.id, props.accountId);
    setBusyId(null);
    if (result.ok) {
      props.onUndone(t.m2.toast.undone + " · " + kindLabel(record.kind));
      // The audit row stays (v3 never deletes them); mark it locally as spent.
      setRows((current) =>
        current.map((row) =>
          row.id === record.id ? { ...row, expiresAt: new Date(0).toISOString() } : row,
        ),
      );
      return;
    }
    props.onFailure(result);
  };

  return (
    <div
      className="scrim"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) props.onClose();
      }}
    >
      <div className="sheet wide" role="dialog" aria-modal="true" aria-label={t.m2.history.title}>
        <h2>{t.m2.history.title}</h2>
        {error ? <p className="surface-detail">{error}</p> : null}
        {loading && rows.length === 0 ? (
          <div className="surface compact">
            <div className="spinner" aria-hidden="true" />
          </div>
        ) : null}
        {!loading && rows.length === 0 ? (
          <div className="surface compact">
            <div className="surface-title">{t.m2.history.empty}</div>
            <div className="surface-detail">{t.m2.history.emptyHint}</div>
          </div>
        ) : null}
        {rows.length > 0 ? (
          <table className="history-table">
            <thead>
              <tr>
                <th>{t.m2.history.colKind}</th>
                <th>{t.m2.history.colTarget}</th>
                <th>{t.m2.history.colTime}</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {rows.map((record) => {
                const expired = isExpired(record);
                return (
                  <tr key={record.id}>
                    <td>{kindLabel(record.kind)}</td>
                    <td className="mono">{record.payload.remoteId ?? record.payload.remote_id ?? "—"}</td>
                    <td className="mono">{record.createdAt.replace("T", " ").slice(0, 19)}</td>
                    <td>
                      {expired ? (
                        <span className="chip unknown">{t.m2.history.expired}</span>
                      ) : record.kind === "purge" ? (
                        <span className="chip unknown">{t.m2.write.notUndoable}</span>
                      ) : (
                        <button className="btn" disabled={busyId === record.id} onClick={() => void undo(record)}>
                          {busyId === record.id ? t.six.loading : t.m2.actions.undo}
                        </button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        ) : null}
        <div className="dialog-actions">
          {hasMore ? (
            <button className="btn" disabled={loading} onClick={() => void load(rows[rows.length - 1]?.id)}>
              {t.m2.history.loadMore}
            </button>
          ) : null}
          <button className="btn" onClick={props.onClose}>
            {t.six.dismiss}
          </button>
        </div>
      </div>
    </div>
  );
}

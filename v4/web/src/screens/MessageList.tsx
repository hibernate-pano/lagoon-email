/**
 * The inbox list (MessageListView.swift, 2752 lines in v3 — this is the M2
 * slice: rows, per-lens empty copy, client-side search, bulk verbs, partial
 * window note).
 *
 * Search is CLIENT-SIDE and makes no request (v4/docs/m1-checklist.md §1.1):
 * v3.2.0's GET /api/search always answers 500 because pass-B references an
 * advice alias it never joins. M1 shipped the filter; M2 keeps it and adds the
 * selection model the write paths need.
 *
 * Selection model (v3 semantics):
 *   - plain click  = open this row (cursor follows);
 *   - ⌘/Ctrl click = toggle membership;
 *   - Shift click  = select the range from the anchor;
 *   - ⌘A           = select everything currently loaded (never "everything on
 *                    the server" — that is the two-stage rule, and M2 keeps the
 *                    first stage only because there is no server-wide verb here).
 */
import { useMemo, useRef, useState, type ReactNode } from "react";
import type { MessageHeader, SyncResponse } from "../core/types";
import type { LensId } from "../core/router";
import type { Outcome } from "../core/async";
import type { WriteBridge } from "../core/uiBridge";
import { AsyncSurface } from "../ui/AsyncSurface";
import { BulkBar } from "../ui/BulkBar";
import { MailRow } from "../ui/MailRow";
import { RowActions } from "../ui/RowActions";
import { t } from "../l10n/zh";

const SEARCH_CAP = 1000;

export interface MessageListProps {
  title: string;
  lens: LensId;
  empty: { title: string; detail?: string };
  outcome: Outcome<SyncResponse>;
  /** Server rows with the optimistic overlay already applied by App. */
  rows: MessageHeader[];
  onRetry: () => void;
  onRefresh: () => void;
  openedId: string | null;
  cursor: string | null;
  selection: Set<string>;
  onRowSelect: (remoteId: string, event: { shiftKey: boolean; metaKey: boolean }) => void;
  writes: WriteBridge;
  onPurge: (remoteId: string) => void;
  onOpenHistory: () => void;
  /** Trash lens only: the folder-level verb, next to the rows it empties. */
  onEmptyTrash?: () => void;
}

function matches(query: string, subject?: string | null, sender?: string | null, snippet?: string | null): boolean {
  const needle = query.trim().toLowerCase();
  if (!needle) return true;
  const haystack = (subject ?? "") + "\n" + (sender ?? "") + "\n" + (snippet ?? "");
  return haystack.toLowerCase().includes(needle);
}

export function MessageList(props: MessageListProps): ReactNode {
  const [query, setQuery] = useState("");
  const listRef = useRef<HTMLDivElement | null>(null);

  const filtered = useMemo(
    () =>
      props.rows
        .slice(0, SEARCH_CAP)
        .filter((m) => matches(query, m.subject, m.fromName ?? m.fromAddress, m.snippet)),
    [props.rows, query],
  );

  // Unknown, not zero: the server omits totalCount when it does not know.
  const total =
    props.outcome.phase === "ready" || props.outcome.phase === "empty"
      ? props.outcome.data.totalCount ?? null
      : null;

  return (
    <div className="pane">
      <div className="pane-head">
        <span className="surface-title">{props.title}</span>
        <span className="badge">{filtered.length + (total === null ? " / —" : " / " + String(total))}</span>
        <span className="spacer" />
        <input
          className="search-input"
          type="search"
          placeholder={t.list.searchPlaceholder}
          value={query}
          aria-label={t.list.searchPlaceholder}
          onChange={(event) => setQuery(event.target.value)}
        />
        {props.lens === "trash" && props.onEmptyTrash ? (
          <button className="btn danger" onClick={props.onEmptyTrash} title={t.m2.actions.emptyTrash}>
            {t.m2.actions.emptyTrash}
          </button>
        ) : null}
        <button className="btn" onClick={props.onOpenHistory} title={t.m2.actions.history}>
          {t.m2.actions.history}
        </button>
        <button className="btn" onClick={props.onRefresh}>
          {t.six.refresh}
        </button>
      </div>
      <div className="pane-body" ref={listRef}>
        <AsyncSurface
          outcome={props.outcome}
          onRetry={props.onRetry}
          onRefresh={props.onRefresh}
          empty={props.empty}
          loadingLabel={t.list.loading}
        >
          {() => (
            <>
              {filtered.length === 0 ? (
                <div className="surface compact" role="status">
                  <div className="surface-title">{t.list.searchEmpty}</div>
                  <div className="surface-detail">{query}</div>
                </div>
              ) : (
                <div className="rows" role="listbox" aria-multiselectable="true" aria-label={props.title}>
                  {filtered.map((message) => (
                    <MailRow
                      key={message.remoteId}
                      message={message}
                      variant="list"
                      thirdLine={message.snippet}
                      opened={props.openedId === message.remoteId}
                      checked={props.selection.has(message.remoteId)}
                      onSelect={(event) => props.onRowSelect(message.remoteId, event)}
                      actions={
                        <RowActions
                          message={message}
                          lens={props.lens}
                          writes={props.writes}
                          onPurge={() => props.onPurge(message.remoteId)}
                        />
                      }
                    />
                  ))}
                </div>
              )}
              {total !== null && total > filtered.length && query.trim() === "" ? (
                <div className="surface compact" role="status">
                  <div className="surface-detail">{t.list.truncated(total - filtered.length)}</div>
                </div>
              ) : null}
            </>
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

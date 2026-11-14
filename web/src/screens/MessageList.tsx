/**
 * The inbox list (MessageListView.swift, 2752 lines in v3 — this is the M2
 * slice: rows, per-lens empty copy, server-side search, bulk verbs, partial
 * window note).
 *
 * Search is the SERVER's job (docs/m1-checklist.md §1.1 said otherwise, and
 * that was wrong): the front end used to filter the rows it happened to have
 * loaded, so mail older than the window could not be found - and the empty copy
 * said "no matches" as if the server had answered. `GET /api/search` searches
 * the whole account (subject, sender, the AI's verdict, and the sealed body of
 * every mail that has been opened), so the list asks the server and shows what
 * the server said, including what it could not reach.
 *
 * Selection model (v3 semantics):
 *   - plain click  = open this row (cursor follows);
 *   - ⌘/Ctrl click = toggle membership;
 *   - Shift click  = select the range from the anchor;
 *   - ⌘A           = select everything currently loaded (never "everything on
 *                    the server" — that is the two-stage rule, and M2 keeps the
 *                    first stage only because there is no server-wide verb here).
 */
import { useRef, type ReactNode } from "react";
import type { MessageHeader, SearchResponse, SyncResponse } from "../core/types";
import type { LensId } from "../core/router";
import type { Outcome } from "../core/async";
import type { WriteBridge } from "../core/uiBridge";
import { emptyStateFor } from "../core/empty";
import { MAX_LIST_ROWS } from "../core/search";
import { AsyncSurface } from "../ui/AsyncSurface";
import { BulkBar } from "../ui/BulkBar";
import { MailRow } from "../ui/MailRow";
import { RowActions } from "../ui/RowActions";
import { t } from "../l10n/zh";

export interface MessageListProps {
  title: string;
  lens: LensId;
  empty: { title: string; detail?: string };
  outcome: Outcome<SyncResponse | SearchResponse>;
  /** Server rows with the optimistic overlay already applied by App. */
  rows: MessageHeader[];
  /** The search box's text. Controlled by App: the query decides the request. */
  query: string;
  onQueryChange: (query: string) => void;
  /** True while the server is answering a query (not the lens list). */
  searching: boolean;
  /** "Load more": the server holds more than the window shows. */
  onLoadMore?: () => void;
  /** False once the window has reached the server's cap. */
  canLoadMore?: boolean;
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

export function MessageList(props: MessageListProps): ReactNode {
  const listRef = useRef<HTMLDivElement | null>(null);

  // Unknown, not zero: the server omits totalCount when it does not know.
  const total =
    props.outcome.phase === "ready" || props.outcome.phase === "empty"
      ? props.outcome.data.totalCount ?? null
      : null;

  // A filtered-to-zero list is not the same as an empty mailbox: the search
  // copy belongs to a query, the lens copy to a known zero with no query.
  const emptyCopy = props.searching
    ? { title: t.list.searchEmpty, detail: props.query }
    : (emptyStateFor(props.lens, props.rows.length) ?? props.empty);

  return (
    <div className="pane">
      <div className="pane-head">
        <span className="surface-title">{props.title}</span>
        <span className="badge">{props.rows.length + (total === null ? " / —" : " / " + String(total))}</span>
        <span className="spacer" />
        <input
          className="search-input"
          type="search"
          placeholder={t.list.searchPlaceholder}
          value={props.query}
          aria-label={t.list.searchPlaceholder}
          onChange={(event) => props.onQueryChange(event.target.value)}
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
          empty={emptyCopy}
          loadingLabel={props.searching ? t.list.searching : t.list.loading}
        >
          {() => (
            <>
              {props.rows.length === 0 ? (
                <div className="surface compact" role="status">
                  <div className="surface-title">{emptyCopy.title}</div>
                  {emptyCopy.detail ? <div className="surface-detail">{emptyCopy.detail}</div> : null}
                </div>
              ) : (
                <div className="rows" role="listbox" aria-multiselectable="true" aria-label={props.title}>
                  {props.rows.map((message) => (
                    <MailRow
                      key={message.remoteId}
                      message={message}
                      variant="list"
                      thirdLine={message.snippet}
                      opened={props.openedId === message.remoteId}
                      isCursor={props.cursor === message.remoteId}
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
              {!props.searching && total !== null && total > props.rows.length ? (
                <div className="surface compact" role="status">
                  <div className="surface-detail">{t.list.truncated(total - props.rows.length)}</div>
                  {props.canLoadMore && props.onLoadMore ? (
                    <div className="surface-actions">
                      <button className="btn" onClick={props.onLoadMore}>
                        {t.list.loadMore}
                      </button>
                    </div>
                  ) : (
                    <div className="surface-detail">{t.list.listCapped(MAX_LIST_ROWS)}</div>
                  )}
                </div>
              ) : null}
              {props.searching ? (
                <div className="surface compact" role="status">
                  <div className="surface-detail">{t.list.searchScope}</div>
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

/**
 * Search: what the reader types, and what the server says back.
 *
 * Search used to be a client-side filter over the rows the list had loaded
 * (up to 500). That is a lie as soon as the mailbox is bigger than the window:
 * the old mail is simply not there to match, and the empty copy says "no
 * matches" as if the server had answered. The server has a real search
 * (`GET /api/search`, two passes: cheap columns in SQL, sealed bodies under a
 * budget) - the front end had simply never called it.
 *
 * This module owns the parts that can be decided without a network: what
 * counts as a query, what the request looks like, how the answer is
 * summarised, and how long the list window may grow.
 */
import type { PartialNote } from "./async";
import type { SearchResponse } from "./types";

/** The server clamps the list to this many rows (contract §4.2). */
export const MAX_LIST_ROWS = 1000;

/** The server's default window. */
export const DEFAULT_LIST_ROWS = 500;

/** The trimmed query. Empty means "not searching". */
export function searchTerm(query: string): string {
  return query.trim();
}

/** Whether there is a query at all. */
export function isSearching(query: string): boolean {
  return searchTerm(query).length > 0;
}

/** The server's search request. */
export function searchRequest(accountId: string, query: string): {
  path: string;
  query: Record<string, string>;
} {
  return {
    path: "/api/search",
    query: { accountId, q: searchTerm(query) },
  };
}

/**
 * What the server's answer says out loud.
 *
 * Two things it can say that the user must hear: the result list is capped
 * (there are more matches than rows), and the budget did not reach every
 * mailbox row (some mails were never opened, so their body was never
 * decrypted and could not be searched).
 */
export function searchNotes(data: SearchResponse): PartialNote[] {
  const notes: PartialNote[] = [];
  if (data.truncated) {
    notes.push({
      tone: "info",
      text: `只返回了前 ${data.results.length} 条，共 ${data.totalCount} 条匹配`,
    });
  }
  if (data.bodyScanSkipped > 0) {
    notes.push({
      tone: "warning",
      text: `有 ${data.bodyScanSkipped} 封的正文没被搜到（解密预算只扫了 ${data.bodyScanLimit} 封）`,
    });
  }
  return notes;
}

/**
 * The next window size for "load more".
 *
 * Doubling keeps the number of clicks small; the server's cap is the ceiling,
 * and the copy says so when the ceiling is reached.
 */
export function nextListLimit(current: number): number {
  return Math.min(Math.max(current, DEFAULT_LIST_ROWS) * 2, MAX_LIST_ROWS);
}

/** Whether the window can still grow. */
export function canLoadMore(limit: number): boolean {
  return limit < MAX_LIST_ROWS;
}

/**
 * A debounced call.
 *
 * The search box must not fire a request per keystroke: the server decrypts
 * sealed bodies under a budget, and a burst of queries would spend it on
 * prefixes the user never meant to search for.
 */
export function debounce<A extends unknown[]>(
  fn: (...args: A) => void,
  wait: number,
): ((...args: A) => void) & { cancel: () => void } {
  let timer: ReturnType<typeof setTimeout> | null = null;
  const wrapped = (...args: A): void => {
    if (timer !== null) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      fn(...args);
    }, wait);
  };
  wrapped.cancel = (): void => {
    if (timer !== null) clearTimeout(timer);
    timer = null;
  };
  return wrapped;
}

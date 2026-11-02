/**
 * Empty-state copy, in one place.
 *
 * "The server answered with nothing" and "we do not know how many there are"
 * are different answers (core/async.ts): only a *known* zero earns the lens
 * copy. A null total means the server did not say, and claiming "收件箱是空的"
 * on an unknown is the same class of lie as rendering a failed search as
 * "没有匹配".
 */
import type { LensId } from "./router";
import { t } from "../l10n/zh";

export interface EmptyCopy {
  title: string;
  detail?: string;
}

export const LENS_EMPTY: Record<LensId, EmptyCopy> = {
  inbox: { title: t.list.empty.inbox[0], detail: t.list.empty.inbox[1] },
  unread: { title: t.list.empty.unread[0], detail: t.list.empty.unread[1] },
  pinned: { title: t.list.empty.pinned[0], detail: t.list.empty.pinned[1] },
  archived: { title: t.list.empty.archived[0], detail: t.list.empty.archived[1] },
  sent: { title: t.list.empty.sent[0], detail: t.list.empty.sent[1] },
  trash: { title: t.list.empty.trash[0], detail: t.list.empty.trash[1] },
};

/** The empty copy for a lens, or null when emptiness is not established. */
export function emptyStateFor(lens: LensId, total: number | null): EmptyCopy | null {
  if (total !== 0) return null;
  return LENS_EMPTY[lens];
}

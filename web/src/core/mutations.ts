/**
 * Optimistic state for the M2 writes, and the rule that makes it safe:
 * **every optimistic change returns its own rollback**.
 *
 * Why an overlay instead of editing the fetched array: the list is owned by
 * useApiOutcome (server data + polling). Mutating that array in place would make
 * the next poll's payload look like "the server disagreed with me", and there
 * would be no way to tell a rollback from a refresh. An overlay keeps the two
 * layers apart:
 *
 *   rendered rows = server rows  -  removed  +  patched
 *
 * A failed write drops its own entry, so the row comes back exactly as it was;
 * a successful write leaves the entry until the next server payload agrees
 * (then clear() drops everything, because the server is now the truth).
 */
import { useCallback, useMemo, useRef, useState } from "react";
import type { MessageHeader } from "./types";

export type Patch = Partial<Pick<MessageHeader, "isRead" | "isPinned" | "isArchived" | "isDeleted">>;

export interface MailboxOverlay {
  rows: (server: MessageHeader[] | undefined) => MessageHeader[];
  /** Hide rows now; the returned function undoes it. */
  remove: (remoteIds: string[]) => () => void;
  /** Flip fields now; the returned function undoes it. */
  patch: (remoteIds: string[], patch: Patch) => () => void;
  /** Server data caught up (or the lens changed): forget every local change. */
  clear: () => void;
  /** How many local changes are in flight — used to mute the "refreshing" chrome. */
  pendingCount: number;
}

export function useMailboxOverlay(): MailboxOverlay {
  // remoteId -> token of the write that hid it. Tokens let two overlapping
  // writes on one row roll back independently.
  const [removed, setRemoved] = useState<Record<string, number>>({});
  const [patched, setPatched] = useState<Record<string, Patch>>({});
  const nextToken = useRef(1);

  const remove = useCallback((remoteIds: string[]) => {
    const token = nextToken.current++;
    setRemoved((current) => {
      const next = { ...current };
      for (const id of remoteIds) next[id] = token;
      return next;
    });
    return () => {
      setRemoved((current) => {
        const next = { ...current };
        for (const id of remoteIds) {
          // Only undo *this* write's optimism; a newer write keeps its own.
          if (next[id] === token) delete next[id];
        }
        return next;
      });
    };
  }, []);

  const patch = useCallback((remoteIds: string[], value: Patch) => {
    const previous: Record<string, Patch | undefined> = {};
    setPatched((current) => {
      const next = { ...current };
      for (const id of remoteIds) {
        previous[id] = current[id];
        next[id] = { ...current[id], ...value };
      }
      return next;
    });
    return () => {
      setPatched((current) => {
        const next = { ...current };
        for (const id of remoteIds) {
          const restored = previous[id];
          if (restored === undefined) delete next[id];
          else next[id] = restored;
        }
        return next;
      });
    };
  }, []);

  const rows = useCallback(
    (server: MessageHeader[] | undefined) => {
      if (!server) return [];
      const visible = server.filter((row) => !removed[row.remoteId]);
      return visible.map((row) => {
        const change = patched[row.remoteId];
        return change ? { ...row, ...change } : row;
      });
    },
    [removed, patched],
  );

  const clear = useCallback(() => {
    setRemoved({});
    setPatched({});
  }, []);

  const pendingCount = useMemo(() => Object.keys(removed).length + Object.keys(patched).length, [removed, patched]);

  // The object itself has to be stable too. Callers write
  //   useMemo(() => overlay.rows(serverRows), [overlay, serverRows])
  // and a fresh literal on every render made that dependency change every
  // render, so the memo never hit: each keystroke in the search box re-filtered
  // and re-mapped the whole (up to 1000 row) list.
  return useMemo(
    () => ({ rows, remove, patch, clear, pendingCount }),
    [rows, remove, patch, clear, pendingCount],
  );
}

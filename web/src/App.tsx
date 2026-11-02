/**
 * The window: boot gate -> (no account ? connect : 3-column shell).
 *
 * Structure mirrors v3's RootView (RootView.swift:17-118): boot gate, banner
 * slot, offline strip, sidebar, two surfaces, reader, palette. M2 adds the write
 * layer on top:
 *
 *   user gesture -> optimistic overlay (returns its own rollback)
 *                -> one endpoint call
 *                -> ok   : toast with actionId (⌘Z), refresh, overlay clears
 *                -> fail : rollback FIRST, then say why, classifying the answer
 *                          (409 capability is not a generic error)
 *
 * The rule that keeps this honest: a failure never leaves the screen showing the
 * thing it claimed to do. Rollback happens before the banner is rendered.
 */
import { useEffect, useMemo, useState, type ReactNode } from "react";
import type {
  AdviceRecord,
  AdviceResponse,
  AiStatus,
  ConnectedAccount,
  FolderCountResponse,
  SentResponse,
  StoreNoticesResponse,
  SyncResponse,
} from "./core/types";
import { apiCall } from "./core/api";
import { COMMON_UNAVAILABLE, describeHttpFailure } from "./core/errors";
import { useApiOutcome, useBoot, useOnline } from "./core/hooks";
import { useMailboxOverlay } from "./core/mutations";
import { BYPASS_CAPABILITY_GATE, UNDO_WINDOW_MS } from "./core/config";
import { LENS_EMPTY } from "./core/empty";
import { targetIdsOf } from "./core/selection";
import {
  bulkAction,
  emptyTrash,
  setPinned,
  setRead,
  singleAction,
  undoBulk,
  undoAction,
  allows,
  type SingleVerb,
  type WriteResult,
} from "./core/writes";
import type { RowVerb, WriteBridge } from "./core/uiBridge";
import { hashFor, navigate, parseHash, type LensId, type Route } from "./core/router";
import { ActionHistoryPanel } from "./screens/ActionHistory";
import { BriefingFeed } from "./screens/BriefingFeed";
import { BootScreen } from "./screens/BootScreen";
import { CommandPalette, buildCommands } from "./screens/CommandPalette";
import { MessageList } from "./screens/MessageList";
import { Onboarding } from "./screens/Onboarding";
import { ReaderPanel } from "./screens/ReaderPanel";
import { ShortcutsDialog } from "./screens/ShortcutsDialog";
import { Sidebar } from "./screens/Sidebar";
import { StatesGallery } from "./screens/StatesGallery";
import { AsyncSurface } from "./ui/AsyncSurface";
import { Banner, Chip } from "./ui/atoms";
import { ConfirmDialog, type ConfirmRequest } from "./ui/ConfirmDialog";
import { Toast, type ToastState } from "./ui/Toast";
import { t } from "./l10n/zh";
import { sidecarUrl } from "virtual:sidecar-env";

const POLL_MS = 30_000;

const LENS_TITLE: Record<LensId, string> = {
  inbox: t.sidebar.inbox,
  unread: t.sidebar.unread,
  pinned: t.sidebar.pinned,
  archived: t.sidebar.archived,
  sent: t.sidebar.sent,
  trash: t.sidebar.trash,
};

const EMPTY_ACCOUNTS: ConnectedAccount[] = [];

interface WriteError {
  title: string;
  detail?: string;
  code?: string | null;
  status?: number;
}

function queryForLens(lens: LensId, accountId: string): Record<string, string> {
  const base: Record<string, string> = { accountId };
  if (lens === "unread") base.unread = "true";
  if (lens === "pinned") base.pinned = "true";
  if (lens === "archived") base.archived = "true";
  if (lens === "trash") base.deleted = "true";
  return base;
}

function patchForVerb(verb: RowVerb): { isPinned?: boolean; isRead?: boolean } | null {
  if (verb === "pin") return { isPinned: true };
  if (verb === "unpin") return { isPinned: false };
  if (verb === "markRead") return { isRead: true };
  if (verb === "markUnread") return { isRead: false };
  return null;
}

function toastTextFor(verb: RowVerb, count: number): string {
  switch (verb) {
    case "archive":
      return t.m2.toast.archived(count);
    case "unarchive":
      return t.m2.toast.unarchived(count);
    case "delete":
      return t.m2.toast.deleted(count);
    case "restore":
      return t.m2.toast.restored(count);
    case "purge":
      return t.m2.toast.purged(count);
    case "pin":
      return t.m2.toast.pinned;
    case "unpin":
      return t.m2.toast.unpinned;
    case "markRead":
      return t.m2.toast.markedRead;
    case "markUnread":
      return t.m2.toast.markedUnread;
  }
}

export function App(): ReactNode {
  const boot = useBoot();
  const online = useOnline();
  const [route, setRoute] = useState<Route>(() => parseHash(window.location.hash));
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [shortcutsOpen, setShortcutsOpen] = useState(false);
  const [connectOpen, setConnectOpen] = useState(false);
  const [density, setDensity] = useState("compact");
  const [historyOpen, setHistoryOpen] = useState(false);

  // selection: cursor is the keyboard highlight, selection is the write target.
  const [cursor, setCursor] = useState<string | null>(null);
  const [openedId, setOpenedId] = useState<string | null>(null);
  const [selection, setSelection] = useState<Set<string>>(() => new Set());
  const [anchor, setAnchor] = useState<string | null>(null);

  const [toast, setToast] = useState<ToastState | null>(null);
  const [writeError, setWriteError] = useState<WriteError | null>(null);
  const [confirm, setConfirm] = useState<ConfirmRequest | null>(null);
  const [confirmBusy, setConfirmBusy] = useState(false);
  const [busy, setBusy] = useState(false);
  const [syncBusy, setSyncBusy] = useState(false);

  const overlay = useMailboxOverlay();

  useEffect(() => {
    const onHash = () => setRoute(parseHash(window.location.hash));
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  // A lens switch is a different mailbox view: local optimism from the previous
  // lens must not leak into it.
  useEffect(() => {
    overlay.clear();
    setSelection(new Set());
    setAnchor(null);
    setOpenedId(null);
    setCursor(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [route.view, route.lens]);

  const go = (next: Route) => {
    navigate(next);
    setRoute(next);
  };

  /* ------------------------------------------------------------ sources --- */

  // Every top-level fetch waits for the shell to report ready: in Tauri mode the
  // WebView loads before the sidecar is listening, so firing on mount produces
  // "not-ready" failures that nothing retries (regressed once already — see
  // docs/m1-checklist.md §1.2).
  const bootReady = boot.phase === "ready";

  const accounts = useApiOutcome<ConnectedAccount[]>({
    enabled: bootReady,
    load: () => apiCall<ConnectedAccount[]>({ method: "GET", path: "/api/accounts" }),
    deps: [bootReady],
    pollMs: POLL_MS,
    translate: {
      errorTitle: "账号列表读取失败",
      unavailableCodes: COMMON_UNAVAILABLE,
      describeCode: describeHttpFailure,
      isEmpty: (data) => data.length === 0,
    },
  });

  const aiStatus = useApiOutcome<AiStatus>({
    enabled: bootReady,
    load: () => apiCall<AiStatus>({ method: "GET", path: "/api/ai-status" }),
    deps: [bootReady],
    pollMs: POLL_MS,
    translate: { errorTitle: "AI 状态读取失败", unavailableCodes: COMMON_UNAVAILABLE, describeCode: describeHttpFailure },
  });

  const notices = useApiOutcome<StoreNoticesResponse>({
    enabled: bootReady,
    load: () => apiCall<StoreNoticesResponse>({ method: "GET", path: "/api/store-notices" }),
    deps: [bootReady],
    pollMs: POLL_MS,
    translate: { errorTitle: t.notices.storeTitle, unavailableCodes: COMMON_UNAVAILABLE, describeCode: describeHttpFailure },
  });

  const accountList =
    accounts.outcome.phase === "ready" || accounts.outcome.phase === "empty" ? accounts.outcome.data : EMPTY_ACCOUNTS;
  const active: ConnectedAccount | undefined = accountList.find((account) => account.isActive) ?? accountList[0];
  const accountId = active?.id;

  const counts = useApiOutcome<FolderCountResponse>({
    enabled: Boolean(accountId),
    deps: [accountId],
    pollMs: POLL_MS,
    load: () =>
      apiCall<FolderCountResponse>({ method: "GET", path: "/api/folder-counts", query: { accountId: accountId ?? "" } }),
    translate: { errorTitle: "计数读取失败", unavailableCodes: COMMON_UNAVAILABLE, describeCode: describeHttpFailure },
  });

  const briefing = useApiOutcome<{
    items: import("./core/types").BriefingItem[];
    omittedCount?: number | null;
    backlogCount?: number | null;
  }>({
    enabled: Boolean(accountId) && route.view === "briefing",
    deps: [accountId, route.view],
    pollMs: POLL_MS,
    load: () => apiCall({ method: "GET", path: "/api/briefing", query: { accountId: accountId ?? "" } }),
    translate: {
      errorTitle: t.briefing.loadFailed,
      unavailableCodes: COMMON_UNAVAILABLE,
      describeCode: describeHttpFailure,
      isEmpty: (data) => data.items.length === 0,
    },
  });

  const advice = useApiOutcome<AdviceResponse>({
    enabled: Boolean(accountId) && route.view === "briefing",
    deps: [accountId, route.view],
    pollMs: POLL_MS,
    load: () => apiCall<AdviceResponse>({ method: "GET", path: "/api/advice", query: { accountId: accountId ?? "" } }),
    translate: { errorTitle: "建议队列读取失败", unavailableCodes: COMMON_UNAVAILABLE, describeCode: describeHttpFailure },
  });

  const messages = useApiOutcome<SyncResponse>({
    enabled: Boolean(accountId) && route.view === "list",
    deps: [accountId, route.view, route.lens],
    pollMs: POLL_MS,
    load: async () => {
      if (!accountId) return { kind: "fail", code: "not-ready", message: t.six.unavailable };
      if (route.lens === "sent") {
        const sent = await apiCall<SentResponse>({ method: "GET", path: "/api/sent", query: { accountId } });
        if (sent.kind !== "ok") return sent;
        return {
          kind: "ok",
          status: sent.status,
          data: {
            cursor: { accountId, totalUnread: 0, lastFetchedAt: null },
            messages: sent.data.messages,
            totalCount: sent.data.totalCount,
          },
        };
      }
      return apiCall<SyncResponse>({ method: "GET", path: "/api/messages", query: queryForLens(route.lens, accountId) });
    },
    translate: {
      errorTitle: t.list.loadFailed,
      unavailableCodes: COMMON_UNAVAILABLE,
      describeCode: describeHttpFailure,
      isEmpty: (data) => data.messages.length === 0,
    },
  });

  const adviceByRemoteId = useMemo(() => {
    const map: Record<string, AdviceRecord> = {};
    if (advice.outcome.phase === "ready" || advice.outcome.phase === "empty") {
      for (const record of advice.outcome.data.advice) map[record.remoteId] = record;
    }
    return map;
  }, [advice.outcome]);

  const countMap = useMemo(() => {
    if (counts.outcome.phase !== "ready" && counts.outcome.phase !== "empty") return undefined;
    const map: Record<string, number> = {};
    for (const entry of counts.outcome.data.counts) map[entry.id] = entry.count;
    return map;
  }, [counts.outcome]);

  const serverRows = useMemo(() => {
    if (route.view === "list" && (messages.outcome.phase === "ready" || messages.outcome.phase === "empty")) {
      return messages.outcome.data.messages;
    }
    if (route.view === "briefing" && (briefing.outcome.phase === "ready" || briefing.outcome.phase === "empty")) {
      return briefing.outcome.data.items.map((item) => item.message);
    }
    return [];
  }, [route.view, messages.outcome, briefing.outcome]);

  const rows = useMemo(() => overlay.rows(serverRows), [overlay, serverRows]);
  const rowsById = useMemo(() => {
    const map: Record<string, (typeof rows)[number]> = {};
    for (const row of rows) map[row.remoteId] = row;
    return map;
  }, [rows]);

  const refreshAll = () => {
    void messages.refresh();
    void briefing.refresh();
    void counts.refresh();
    void accounts.refresh();
  };

  /**
   * `POST /api/sync` answers 204 at once: it starts a round, it does not wait
   * for one. The refresh is what makes the result visible, so it runs either
   * way - a request that was accepted still produced a round.
   */
  const syncNow = async () => {
    if (!accountId || syncBusy) return;
    setSyncBusy(true);
    try {
      const result = await apiCall<null>({ method: "POST", path: "/api/sync" });
      if (result.kind !== "ok") {
        setToast({ id: Date.now(), text: t.sync.failed });
      }
      refreshAll();
    } finally {
      setSyncBusy(false);
    }
  };

  /* ------------------------------------------------------------- writes --- */

  async function dispatch(verb: RowVerb, remoteId: string): Promise<WriteResult> {
    if (!accountId) return { ok: false, kind: "transport", code: null, status: 0, message: t.six.unavailable };
    switch (verb) {
      case "pin":
        return setPinned(remoteId, accountId, true);
      case "unpin":
        return setPinned(remoteId, accountId, false);
      case "markRead":
        return setRead(remoteId, accountId, true);
      case "markUnread":
        return setRead(remoteId, accountId, false);
      default:
        return singleAction(verb as SingleVerb, remoteId, accountId);
    }
  }

  async function runRowVerb(verb: RowVerb, remoteId: string) {
    if (!active || busy) return;
    const row = rowsById[remoteId];
    setBusy(true);
    // 1) optimism, and keep its rollback
    const patch = patchForVerb(verb);
    const hide = patch === null;
    const rollback = hide ? overlay.remove([remoteId]) : overlay.patch([remoteId], patch);
    // 2) the call
    const result = await dispatch(verb, remoteId);
    setBusy(false);
    // 3) failure: roll back BEFORE telling the user anything
    if (!result.ok) {
      rollback();
      setWriteError({
        title: t.m2.write.failedTitle + " · " + verbLabel(verb),
        detail: result.message + " — " + t.m2.write.rolledBack,
        code: result.code,
        status: result.status,
      });
      return;
    }
    setWriteError(null);
    setToast({ id: Date.now(), text: toastTextFor(verb, 1), actionId: result.actionId });
    if (row && hide) {
      setOpenedId((current) => (current === remoteId ? null : current));
      setCursor((current) => (current === remoteId ? null : current));
      setSelection((current) => {
        if (!current.has(remoteId)) return current;
        const next = new Set(current);
        next.delete(remoteId);
        return next;
      });
    }
    refreshAll();
  }

  async function runBulk(verb: "archive" | "delete") {
    if (!active || busy) return;
    const ids = [...selection];
    if (ids.length === 0) return;
    setBusy(true);
    const rollback = overlay.remove(ids);
    const result = await bulkAction(verb, ids, accountId ?? "");
    setBusy(false);
    if (!result.ok) {
      rollback();
      setWriteError({
        title: t.m2.write.failedTitle,
        detail: result.message + " — " + t.m2.write.rolledBack,
        code: result.code,
        status: result.status,
      });
      return;
    }
    const okItems = result.items.filter((item) => item.ok);
    const failedItems = result.items.filter((item) => !item.ok);
    // Partial success: everything is back to server truth, then re-hide only the
    // rows the server actually moved.
    rollback();
    if (okItems.length > 0) overlay.remove(okItems.map((item) => item.remoteId));
    setSelection(new Set());
    setAnchor(null);
    setWriteError(
      failedItems.length > 0
        ? {
            title: t.m2.bulk.partial(okItems.length, failedItems.length),
            detail:
              describeHttpFailure(failedItems[0].errorCode ?? null, 409) +
              (result.truncatedCount ? " · " + t.m2.bulk.truncated(result.truncatedCount) : ""),
            code: failedItems[0].errorCode ?? null,
          }
        : null,
    );
    setToast({
      id: Date.now(),
      text: toastTextFor(verb === "archive" ? "archive" : "delete", okItems.length),
      actionIds: okItems.map((item) => item.actionId).filter((id): id is number => typeof id === "number"),
    });
    refreshAll();
  }

  async function undoLatest() {
    if (!toast || busy) return;
    const { actionId, actionIds } = toast;
    if (actionId === undefined && (actionIds?.length ?? 0) === 0) return;
    setBusy(true);
    const result =
      actionIds && actionIds.length > 0
        ? await undoBulk(actionIds, accountId ?? "")
        : await undoAction(actionId as number, accountId ?? "");
    setBusy(false);
    if (!result.ok) {
      setWriteError({
        title: t.m2.write.failedTitle + " · " + t.m2.actions.undo,
        detail: result.message,
        code: result.code,
        status: result.status,
      });
      return;
    }
    setWriteError(null);
    setToast({ id: Date.now(), text: t.m2.toast.undone });
    refreshAll();
  }

  function requestPurge(remoteId: string) {
    setConfirm({
      title: t.m2.confirm.purgeTitle,
      message: t.m2.confirm.purgeMessage,
      destructive: true,
      confirmLabel: t.m2.actions.purge,
      onConfirm: async () => {
        setConfirmBusy(true);
        await runRowVerb("purge", remoteId);
        setConfirmBusy(false);
        setConfirm(null);
      },
    });
  }

  function requestEmptyTrash() {
    setConfirm({
      title: t.m2.confirm.emptyTrashTitle,
      message: t.m2.confirm.emptyTrashMessage,
      destructive: true,
      confirmLabel: t.m2.actions.emptyTrash,
      onConfirm: async () => {
        setConfirmBusy(true);
        const ids = rows.map((row) => row.remoteId);
        const rollback = overlay.remove(ids);
        const result = await emptyTrash(accountId ?? "");
        setConfirmBusy(false);
        setConfirm(null);
        if (!result.ok) {
          rollback();
          setWriteError({ title: t.m2.write.failedTitle, detail: result.message, code: result.code, status: result.status });
          return;
        }
        setWriteError(null);
        setToast({ id: Date.now(), text: t.m2.toast.emptyTrashDone(result.purged ?? 0) });
        refreshAll();
      },
    });
  }

  function verbLabel(verb: RowVerb): string {
    const table: Record<string, string> = {
      archive: t.m2.actions.archive,
      unarchive: t.m2.actions.unarchive,
      delete: t.m2.actions.delete,
      restore: t.m2.actions.restore,
      purge: t.m2.actions.purge,
      pin: t.m2.actions.pin,
      unpin: t.m2.actions.unpin,
      markRead: t.m2.actions.markRead,
      markUnread: t.m2.actions.markUnread,
    };
    return table[verb] ?? verb;
  }

  /* --------------------------------------------------------- capability --- */

  const caps = active?.capabilities;
  const canArchive = BYPASS_CAPABILITY_GATE ? true : allows(caps?.archiveFolder);
  const canDelete = BYPASS_CAPABILITY_GATE ? true : allows(caps?.trashFolder);
  const canPurge = BYPASS_CAPABILITY_GATE ? true : allows(caps?.uidplus);
  const capabilityHint = BYPASS_CAPABILITY_GATE && !allows(caps?.archiveFolder)
    ? t.m2.write.bypassOn
    : t.m2.write.capabilityHint;

  const writes: WriteBridge = {
    busy,
    canArchive,
    canDelete,
    canPurge,
    archiveHint: capabilityHint,
    deleteHint: BYPASS_CAPABILITY_GATE ? t.m2.write.bypassOn : t.m2.write.capabilityHint,
    purgeHint: BYPASS_CAPABILITY_GATE ? t.m2.write.bypassOn : t.m2.write.capabilityHint,
    row: (verb, remoteId) => void runRowVerb(verb, remoteId),
    bulk: (verb) => void runBulk(verb),
    selectionCount: selection.size,
    clearSelection: () => {
      setSelection(new Set());
      setAnchor(null);
    },
  };

  /* ---------------------------------------------------------- selection --- */

  const targetIds = (): string[] => targetIdsOf(selection, openedId, cursor);

  const handleRowSelect = (remoteId: string, event: { shiftKey: boolean; metaKey: boolean }) => {
    setOpenedId(remoteId);
    setCursor(remoteId);
    if (event.shiftKey && anchor) {
      const ids = rows.map((row) => row.remoteId);
      const from = ids.indexOf(anchor);
      const to = ids.indexOf(remoteId);
      if (from >= 0 && to >= 0) {
        const [lo, hi] = from <= to ? [from, to] : [to, from];
        setSelection(new Set(ids.slice(lo, hi + 1)));
        return;
      }
    }
    if (event.metaKey) {
      setSelection((current) => {
        const next = new Set(current);
        if (next.has(remoteId)) next.delete(remoteId);
        else next.add(remoteId);
        return next;
      });
      setAnchor(remoteId);
      return;
    }
    setSelection(new Set());
    setAnchor(remoteId);
  };

  /* ----------------------------------------------------------- keyboard --- */

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      const typing =
        target !== null && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable);
      const mod = event.metaKey || event.ctrlKey;

      // ⌘K is safe inside a text field: it opens the palette, it does not
      // touch mail.
      if (mod && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setPaletteOpen((open) => !open);
        return;
      }
      // Everything below acts on mail. A keystroke meant for a text field must
      // never reach it: ⌘⌫ in an input deletes text, and acting instead on the
      // cursor would delete a row the user cannot even see (the cursor is not
      // cleared when the lens or the filter changes the visible rows).
      if (typing) return;

      if (mod && event.key === "/") {
        event.preventDefault();
        setShortcutsOpen(true);
        return;
      }
      if (mod && event.key.toLowerCase() === "z") {
        event.preventDefault();
        void undoLatest();
        return;
      }
      if (mod && (event.key === "Backspace" || event.key === "Delete")) {
        event.preventDefault();
        for (const id of targetIds()) void runRowVerb("delete", id);
        return;
      }
      if (mod && event.shiftKey && event.key.toLowerCase() === "a") {
        event.preventDefault();
        for (const id of targetIds()) void runRowVerb("archive", id);
        return;
      }
      if (mod && event.key.toLowerCase() === "a") {
        event.preventDefault();
        setSelection(new Set(rows.map((row) => row.remoteId)));
        return;
      }
      if (event.key === "Escape") {
        if (paletteOpen) setPaletteOpen(false);
        else if (shortcutsOpen) setShortcutsOpen(false);
        else if (historyOpen) setHistoryOpen(false);
        else {
          setOpenedId(null);
          setSelection(new Set());
        }
        return;
      }
      if (typing || event.metaKey || event.ctrlKey) return;

      if (event.key === "j" || event.key === "J" || event.key === "ArrowDown" || event.key === "ArrowUp" || event.key === "k" || event.key === "K") {
        const ids = rows.map((row) => row.remoteId);
        if (ids.length === 0) return;
        event.preventDefault();
        const down = event.key === "j" || event.key === "J" || event.key === "ArrowDown";
        const current = cursor === null ? -1 : ids.indexOf(cursor);
        const next = Math.max(0, Math.min(ids.length - 1, current + (down ? 1 : -1)));
        setCursor(ids[next] ?? null);
        return;
      }
      if (event.key === "Enter" && cursor) {
        event.preventDefault();
        setOpenedId(cursor);
        return;
      }
      if (event.key === "p" || event.key === "P") {
        const id = cursor ?? openedId;
        const row = id ? rowsById[id] : undefined;
        if (row) {
          event.preventDefault();
          void runRowVerb(row.isPinned ? "unpin" : "pin", row.remoteId);
        }
        return;
      }
      if (event.key === "r" || event.key === "R" || (mod && event.key.toLowerCase() === "n")) {
        event.preventDefault();
        setToast({ id: Date.now(), text: t.m2.keyboard.reply + "（M3）" });
        return;
      }
      if (event.key === "?") {
        setShortcutsOpen(true);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  /* ------------------------------------------------------------- render --- */

  const commands = useMemo(
    () =>
      buildCommands({
        go: (view, lens) => go({ view, lens }),
        openShortcuts: () => setShortcutsOpen(true),
        openStates: () => go({ view: "states", lens: "inbox" }),
        openConnect: () => setConnectOpen(true),
        close: () => setPaletteOpen(false),
      }),
    [],
  );

  const sidecarLabel = t.onboarding.sidecarOk(sidecarUrl || "—", accountList.length);
  const noticesList =
    notices.outcome.phase === "ready" || notices.outcome.phase === "empty" ? notices.outcome.data.notices : [];

  const titlebar = (
    <header className="titlebar">
      <span className="brand">{t.app.name}</span>
      <span className="badge">{t.app.version}</span>
      <span className="badge">{active ? active.email : t.onboarding.title}</span>
      <span className="spacer" />
      {BYPASS_CAPABILITY_GATE ? <Chip tone="warn">{t.m2.write.bypassOn}</Chip> : null}
      {aiStatus.outcome.phase === "ready" ? (
        <Chip tone={aiStatus.outcome.data.configured ? "ok" : "unknown"}>
          {"AI: " + (aiStatus.outcome.data.configured ? "已配置" : "未配置")}
        </Chip>
      ) : null}
      <button className="btn" onClick={() => setDensity(nextDensity(density))}>
        {density}
      </button>
      <button className="btn" onClick={() => void syncNow()} disabled={!accountId || syncBusy}>
        {syncBusy ? t.sync.running : t.sync.now}
      </button>
      <button className="btn" onClick={() => setHistoryOpen(true)} disabled={!accountId}>
        {t.m2.actions.history}
      </button>
      <button className="btn" onClick={() => setShortcutsOpen(true)}>⌘/</button>
      <button className="btn" onClick={() => setPaletteOpen(true)}>⌘K</button>
    </header>
  );

  const body = (): ReactNode => {
    if (boot.phase === "starting") return <BootScreen boot={boot} phase="starting" />;
    if (boot.phase === "failed") return <BootScreen boot={boot} phase="failed" />;

    if (accounts.outcome.phase === "loading") {
      return (
        <div className="center-wrap">
          <div className="center-card">
            <div className="spinner" aria-hidden="true" />
            <p>{t.six.loading}</p>
          </div>
        </div>
      );
    }
    if (accounts.outcome.phase === "error" || accounts.outcome.phase === "offline" || accounts.outcome.phase === "unavailable") {
      return (
        <div className="center-wrap">
          <div className="center-card">
            <AsyncSurface outcome={accounts.outcome} onRetry={accounts.refresh} empty={{ title: t.onboarding.title }}>
              {() => null}
            </AsyncSurface>
          </div>
        </div>
      );
    }

    const list =
      accounts.outcome.phase === "ready" || accounts.outcome.phase === "empty" ? accounts.outcome.data : [];

    if (route.view === "states") {
      return (
        <div className="shell solo">
          <StatesGallery />
        </div>
      );
    }

    if (list.length === 0 || connectOpen) {
      return (
        <Onboarding
          sidecarLabel={sidecarLabel}
          onOpenPalette={() => setPaletteOpen(true)}
          onConnected={() => {
            setConnectOpen(false);
            accounts.refresh();
          }}
        />
      );
    }

    if (!active) return null;

    return (
      <div className="shell">
        <Sidebar route={route} counts={countMap} disabled={false} onNavigate={(next) => go(next)} />
        <div className="panes">
          {route.view === "briefing" ? (
            <BriefingFeed
              outcome={briefing.outcome}
              adviceByRemoteId={adviceByRemoteId}
              syncHealth={active.syncHealth}
              hasUserGroups={false}
              onRetry={briefing.refresh}
              onRefresh={briefing.refresh}
              openedId={openedId}
              cursor={cursor}
              selection={selection}
              onRowSelect={handleRowSelect}
              writes={writes}
              onPurge={requestPurge}
              onOpenHistory={() => setHistoryOpen(true)}
            />
          ) : (
            <MessageList
              title={LENS_TITLE[route.lens]}
              lens={route.lens}
              empty={LENS_EMPTY[route.lens]}
              outcome={messages.outcome}
              rows={rows}
              onRetry={messages.refresh}
              onRefresh={messages.refresh}
              openedId={openedId}
              cursor={cursor}
              selection={selection}
              onRowSelect={handleRowSelect}
              writes={writes}
              onPurge={requestPurge}
              onOpenHistory={() => setHistoryOpen(true)}
              onEmptyTrash={route.lens === "trash" ? requestEmptyTrash : undefined}
            />
          )}
          <ReaderPanel
            remoteId={openedId}
            account={active}
            aiStatus={aiStatus.outcome.phase === "ready" ? aiStatus.outcome.data : undefined}
            writes={writes}
            onPurge={requestPurge}
            onOpenHistory={() => setHistoryOpen(true)}
            onClose={() => setOpenedId(null)}
          />
        </div>
      </div>
    );
  };

  return (
    <div className="app" data-density={density}>
      {titlebar}
      {online ? null : (
        <div className="offline-strip" role="status">
          {t.six.offline}
        </div>
      )}
      {notices.outcome.phase === "ready" && noticesList.length > 0 ? (
        <Banner tone="warning" title={t.notices.storeTitle} detail={noticesList[0].detail ?? noticesList[0].id} />
      ) : null}
      {writeError ? (
        <Banner
          tone="error"
          title={writeError.title}
          detail={writeError.detail}
          onDismiss={() => setWriteError(null)}
        />
      ) : null}
      {body()}
      <Toast
        toast={toast}
        windowMs={UNDO_WINDOW_MS}
        onUndo={() => void undoLatest()}
        onDismiss={() => setToast(null)}
      />
      <ConfirmDialog request={confirm} busy={confirmBusy} onCancel={() => setConfirm(null)} />
      {historyOpen && accountId ? (
        <ActionHistoryPanel
          accountId={accountId}
          onClose={() => setHistoryOpen(false)}
          onUndone={(text) => setToast({ id: Date.now(), text })}
          onFailure={(failure) =>
            setWriteError({ title: t.m2.write.failedTitle + " · " + t.m2.actions.undo, detail: failure.message, code: failure.code })
          }
        />
      ) : null}
      {paletteOpen ? <CommandPalette commands={commands} onClose={() => setPaletteOpen(false)} /> : null}
      {shortcutsOpen ? <ShortcutsDialog onClose={() => setShortcutsOpen(false)} /> : null}
      <span className="visually-hidden" aria-live="polite">
        {hashFor(route)}
      </span>
    </div>
  );
}

function nextDensity(current: string): string {
  if (current === "comfortable") return "compact";
  if (current === "compact") return "dense";
  return "comfortable";
}

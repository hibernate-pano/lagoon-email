/**
 * Data plumbing: one polling pattern, one boot probe.
 *
 * The polling rules are copied from v3 rather than invented (PollClock.swift:34,
 * DirectoryStore.swift:19): poll every 30s, skip the tick while the tab is
 * hidden, and let a newer response win. v3 needed a whole type (RefreshGate) to
 * keep "who may commit" honest; here the same job is a generation counter, for
 * the same reason — a slow poll that lands after a local change must not
 * overwrite it.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { apiHealth, isTauriMode, type ApiRequest, type CallResult } from "./api";
import { fromCall, type Outcome, type TranslateOptions } from "./async";
import { t } from "../l10n/zh";

/** True while the machine claims to have a network path. */
export function useOnline(): boolean {
  const [online, setOnline] = useState<boolean>(() =>
    typeof navigator === "undefined" ? true : navigator.onLine,
  );
  useEffect(() => {
    const up = () => setOnline(true);
    const down = () => setOnline(false);
    window.addEventListener("online", up);
    window.addEventListener("offline", down);
    return () => {
      window.removeEventListener("online", up);
      window.removeEventListener("offline", down);
    };
  }, []);
  return online;
}

export interface ApiOutcomeConfig<T> {
  load: () => Promise<CallResult<T>>;
  /** Values that invalidate the request; stringified for the dependency key. */
  deps: readonly unknown[];
  enabled?: boolean;
  pollMs?: number;
  translate: TranslateOptions<T>;
}

export interface ApiOutcomeState<T> {
  outcome: Outcome<T>;
  refresh: () => void;
}

export function useApiOutcome<T>(config: ApiOutcomeConfig<T>): ApiOutcomeState<T> {
  const [outcome, setOutcome] = useState<Outcome<T>>({ phase: "loading" });
  const generation = useRef(0);
  const loadRef = useRef(config.load);
  const translateRef = useRef(config.translate);
  loadRef.current = config.load;
  translateRef.current = config.translate;

  const enabled = config.enabled ?? true;
  const depsKey = config.deps.map((value) => String(value)).join("\u0001");

  const run = useCallback(async () => {
    if (!enabled) return;
    const mine = ++generation.current;
    const result = await loadRef.current();
    // A newer request started while this one was in flight; its answer is at
    // least as fresh, so committing this one would resurrect stale rows.
    if (mine !== generation.current) return;
    setOutcome(fromCall(result, translateRef.current));
  }, [enabled]);

  useEffect(() => {
    if (!enabled) return;
    setOutcome({ phase: "loading" });
    void run();
    // depsKey is the caller's dependency list, stringified.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [depsKey, enabled, run]);

  useEffect(() => {
    const pollMs = config.pollMs;
    if (!enabled || !pollMs) return;
    const id = window.setInterval(() => {
      // A hidden tab has nothing to show and the server polls nothing, so the
      // only thing a background tick buys is wake-ups (PollClock.swift:34).
      if (document.hidden) return;
      void run();
    }, pollMs);
    return () => window.clearInterval(id);
  }, [config.pollMs, enabled, run]);

  return { outcome, refresh: () => void run() };
}

export type BootPhase = "starting" | "ready" | "failed";

export interface BootState {
  phase: BootPhase;
  detail?: string;
  retry: () => void;
  transport: string;
}

const BOOT_DEADLINE_MS = 20_000;
const BOOT_PROBE_MS = 500;

/**
 * Boot probe.
 *
 * Tauri: boot_status + the "boot-status" event (contract §4.1/§4.4) — the shell
 * owns the sidecar, so the shell owns the phase.
 * Browser: probe /healthz every 500ms for up to 20s and derive the same three
 * phases. Same screen, same sentences, both modes.
 */
export function useBoot(): BootState {
  const [phase, setPhase] = useState<BootPhase>("starting");
  const [detail, setDetail] = useState<string | undefined>(undefined);
  const [attempt, setAttempt] = useState(0);
  const tauri = isTauriMode();

  useEffect(() => {
    if (!tauri) return;
    let disposed = false;
    let stop: (() => void) | undefined;
    void (async () => {
      const core = await import("@tauri-apps/api/core");
      const event = await import("@tauri-apps/api/event");
      // Subscribe first, then ask once. Order matters: the shell can flip to
      // ready between the invoke and the listen, and an event emitted into
      // that gap is lost forever — the window then sits on "服务器启动中"
      // (observed 2026-10-29). A stale "starting" echo is also ignored once a
      // settled phase has been seen, so the catch-up invoke cannot regress it.
      let sawSettled = false;
      const apply = (payload: { phase: BootPhase; error?: { message?: string } }) => {
        if (disposed) return;
        if (payload.phase === "starting" && sawSettled) return;
        if (payload.phase !== "starting") sawSettled = true;
        setPhase(payload.phase);
        setDetail(payload.error?.message);
      };
      const unlisten = await event.listen("boot-status", (e) => {
        apply(e.payload as { phase: BootPhase; error?: { message?: string } });
      });
      stop = unlisten;
      apply((await core.invoke("boot_status")) as { phase: BootPhase; error?: { message?: string } });
    })();
    return () => {
      disposed = true;
      stop?.();
    };
  }, [tauri]);

  useEffect(() => {
    if (tauri) return;
    let cancelled = false;
    const deadline = Date.now() + BOOT_DEADLINE_MS;
    setPhase("starting");
    setDetail(undefined);

    const probe = async () => {
      const res = await apiHealth();
      if (cancelled) return;
      if (res.kind === "ok") {
        setPhase("ready");
        setDetail(undefined);
        return true;
      }
      const message =
        res.kind === "fail" ? res.message : t.six.serverCode + " " + String(res.status);
      if (Date.now() >= deadline) {
        setPhase("failed");
        setDetail(message);
        return true;
      }
      setDetail(message);
      return false;
    };

    void (async () => {
      for (;;) {
        if (cancelled) return;
        const done = await probe();
        if (done || cancelled) return;
        await new Promise((resolve) => window.setTimeout(resolve, BOOT_PROBE_MS));
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [tauri, attempt]);

  return {
    phase,
    detail,
    transport: transportLine(),
    retry: () => setAttempt((value) => value + 1),
  };
}

function transportLine(): string {
  if (isTauriMode()) return "Tauri IPC（token 只在外壳进程里）";
  return "浏览器直连（dev 模式；生产走 Tauri IPC）";
}

/** A one-shot request with the same three-way result as the polling hook. */
export function useOneShot<T>(): {
  result: Outcome<T> | undefined;
  run: (request: ApiRequest, translate: TranslateOptions<T>) => Promise<void>;
  reset: () => void;
} {
  const [result, setResult] = useState<Outcome<T> | undefined>(undefined);
  const run = useCallback(async (request: ApiRequest, translate: TranslateOptions<T>) => {
    setResult({ phase: "loading" });
    const { apiCall } = await import("./api");
    const res = await apiCall<T>(request);
    setResult(fromCall(res, translate));
  }, []);
  return { result, run, reset: () => setResult(undefined) };
}


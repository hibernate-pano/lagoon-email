/**
 * The one API entry point (docs/ipc-contract.md §4.2).
 *
 * Two transports, one surface:
 *   - Tauri:    invoke("api", { request })  -> the Rust shell proxies, the
 *               token never enters this process (contract §1.1).
 *   - Browser:  fetch() straight at the sidecar with the dev-only Bearer
 *               token read from v4/.dev/web.env via the virtual module
 *               (contract §5). Development and Playwright only.
 *
 * Nothing else in the app is allowed to call fetch/invoke. That is not a style
 * preference: it is what keeps the token out of the DOM, out of URLs and out of
 * localStorage, and it is what makes "ok:false vs 4xx" a single decision
 * instead of one per screen.
 */
import { hasSidecar, sidecarUrl } from "virtual:sidecar-env";

export type ApiMethod = "GET" | "POST" | "PATCH" | "DELETE";

export interface ApiRequest {
  method: ApiMethod;
  /** Must start with "/api/" or be exactly "/healthz" (contract §4.2). */
  path: string;
  query?: Record<string, string | number | boolean | undefined | null>;
  /** JSON body. undefined = no body. */
  body?: unknown;
}

/** Failures that are *not* an HTTP answer from the server (contract §4.2). */
export type ApiFailureCode = "not-ready" | "transport" | "timeout" | "bad-path" | "bad-request";

export type ApiResponse =
  | { ok: true; status: number; body: unknown }
  | { ok: false; status: 0; error: { code: ApiFailureCode; message: string } };

/** connection timeout: the port is either listening or it is not (5s per contract). */
const CONNECT_TIMEOUT_MS = 5_000;
/** read timeout: body/attachment paths can legitimately be slow (60s per contract). */
const READ_TIMEOUT_MS = 60_000;

/** True when running inside the Tauri shell (contract §4.2: invoke("api")). */
export function isTauriMode(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

function isAllowedPath(path: string): boolean {
  if (path === "/healthz") return true;
  if (path.startsWith("/api/") && !path.includes("//") && !path.includes("..")) return true;
  return false;
}

function buildQuery(query: ApiRequest["query"]): string {
  if (!query) return "";
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null) continue;
    params.set(key, String(value));
  }
  const text = params.toString();
  return text ? `?${text}` : "";
}

async function viaTauri(request: ApiRequest): Promise<ApiResponse> {
  const core = await import("@tauri-apps/api/core");
  return (await core.invoke("api", { request })) as ApiResponse;
}

async function viaFetch(request: ApiRequest): Promise<ApiResponse> {
  if (!hasSidecar) {
    return {
      ok: false,
      status: 0,
      error: {
        code: "not-ready",
        message:
          "浏览器模式没有配到边车：v4/.dev/web.env 缺失或不完整（先运行 bash v4/scripts/sidecar-dev.sh start 再重启 npm run dev）。",
      },
    };
  }

  const controller = new AbortController();
  let timer = setTimeout(() => controller.abort(), CONNECT_TIMEOUT_MS);
  const headers: Record<string, string> = { Accept: "application/json" };
  // Same-origin request: the Vite dev proxy attaches Authorization and forwards
  // to the sidecar, so no token exists in this process (see vite.config.ts).
  const init: RequestInit = { method: request.method, headers, signal: controller.signal };
  if (request.body !== undefined) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(request.body);
  }

  try {
    const res = await fetch(request.path + buildQuery(request.query), init);
    // Headers arrived: the connection is up, so the generous read budget applies
    // from here (a 30s IMAP-backed body is not a hung port).
    clearTimeout(timer);
    timer = setTimeout(() => controller.abort(), READ_TIMEOUT_MS);
    const contentType = res.headers.get("content-type") ?? "";
    let body: unknown;
    if (contentType.includes("application/json")) {
      body = await res.json();
    } else {
      body = await res.text();
    }
    clearTimeout(timer);
    // 4xx/5xx are answers, not transport failures — the caller must be able to
    // read status and the {"error": ...} code and decide (contract §4.2 rule 2).
    return { ok: true, status: res.status, body };
  } catch (error) {
    clearTimeout(timer);
    const aborted = error instanceof DOMException && error.name === "AbortError";
    return {
      ok: false,
      status: 0,
      error: {
        code: aborted ? "timeout" : "transport",
        message: aborted
          ? "边车没有在超时时间内答复（可能仍在启动或已退出）。"
          : `连不上边车：${error instanceof Error ? error.message : String(error)}`,
      },
    };
  }
}

/** The only function that talks to the sidecar. */
export async function api(request: ApiRequest): Promise<ApiResponse> {
  if (!isAllowedPath(request.path)) {
    return {
      ok: false,
      status: 0,
      error: { code: "bad-path", message: `非法路径（只允许 /api/* 与 /healthz）：${request.path}` },
    };
  }
  try {
    return isTauriMode() ? await viaTauri(request) : await viaFetch(request);
  } catch (error) {
    return {
      ok: false,
      status: 0,
      error: { code: "transport", message: error instanceof Error ? error.message : String(error) },
    };
  }
}

/** A typed, three-way result. HTTP errors stay distinct from transport errors. */
export type CallResult<T> =
  | { kind: "ok"; status: number; data: T }
  | { kind: "http"; status: number; code: string | null; body: unknown }
  | { kind: "fail"; code: ApiFailureCode; message: string };

function errorCodeOf(body: unknown): string | null {
  if (body && typeof body === "object" && "error" in body) {
    const code = (body as { error: unknown }).error;
    return typeof code === "string" ? code : null;
  }
  return null;
}

/** GET/POST with JSON decode + the ok/http/fail split the UI states are built on. */
export async function apiCall<T>(request: ApiRequest): Promise<CallResult<T>> {
  const res = await api(request);
  if (!res.ok) return { kind: "fail", code: res.error.code, message: res.error.message };
  if (res.status < 200 || res.status >= 300) {
    return { kind: "http", status: res.status, code: errorCodeOf(res.body), body: res.body };
  }
  return { kind: "ok", status: res.status, data: res.body as T };
}

/** Health probe. The one endpoint that answers text/plain "ok". */
export async function apiHealth(): Promise<CallResult<string>> {
  const res = await api({ method: "GET", path: "/healthz" });
  if (!res.ok) return { kind: "fail", code: res.error.code, message: res.error.message };
  if (res.status !== 200) {
    return { kind: "http", status: res.status, code: errorCodeOf(res.body), body: res.body };
  }
  return { kind: "ok", status: 200, data: typeof res.body === "string" ? res.body : "" };
}

/** Browser-mode diagnostics for the boot screen. Never includes the token. */
export function transportDescription(): string {
  if (isTauriMode()) return "Tauri IPC（token 只在外壳进程里）";
  return sidecarUrl ? "浏览器模式 · Vite 代理 → " + sidecarUrl : "浏览器模式（未配置边车）";
}

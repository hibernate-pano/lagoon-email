/**
 * Server error codes -> the sentence the user sees.
 *
 * One file, because these sentences must be identical everywhere a code can
 * appear (checklist §2: "连接失败按 code 区分"). The codes are the server's
 * stable labels (recon/server-contract.md §2) — never upstream IMAP/LLM text,
 * which the server does not return either.
 */
import { t } from "../l10n/zh";
import type { UnavailableReason } from "./async";

export interface CodeCopy {
  reason: UnavailableReason;
  title: string;
  detail?: string;
}

/** 401 for any endpoint: the page cannot do better than say so. */
export const UNAUTHORIZED: CodeCopy = {
  reason: "unauthorized",
  title: "未授权（401）",
  detail: "边车配了 token，但前端没有带上或带错了。浏览器模式请重启 bash v4/scripts/sidecar-dev.sh（会重写 v4/.dev/web.env）。",
};

export const COMMON_UNAVAILABLE: Record<string, CodeCopy> = {
  "api-unauthorized": UNAUTHORIZED,
  "forbidden-host": {
    reason: "unauthorized",
    title: "被 Host 守卫拒绝（403）",
    detail: "请求的 Host 不在白名单（127.0.0.1 / localhost / ::1）。浏览器模式不该出现这个。",
  },
  "unknown-account": {
    reason: "no-account",
    title: "这个账号不在库里",
    detail: "服务端返回 404 unknown-account：账号被删了，或者 id 过时。刷新账号列表即可。",
  },
  "malformed-accountId": {
    reason: "capability",
    title: "账号 id 格式不对（400）",
    detail: "这是前端 bug，不是服务端的问题。",
  },
  "provider-not-configured": {
    reason: "not-configured",
    title: "服务端没有配置这个邮箱服务商（503）",
  },
  "ai-not-configured": {
    reason: "not-configured",
    title: t.reader.summaryNotConfigured,
  },
  "ai-credit-exhausted": {
    reason: "not-configured",
    title: t.reader.summaryCredit,
  },
  "ai-circuit-open": {
    reason: "not-configured",
    title: t.reader.summaryCircuit,
  },
  "sent-unavailable": {
    reason: "capability",
    title: "这个账号没有「已发送」文件夹",
    detail: "服务端返回 404 sent-unavailable：这是确定的结论，重试不会变。",
  },
};

/**
 * Detail text for an HTTP failure whose code has no sentence above.
 *
 * The 404-with-empty-body case is called out because the checklist measured it
 * (m1-checklist §1, S6): an unknown route answers 404 with *no JSON envelope*,
 * so a front-end that assumes {error} everywhere renders blank or crashes.
 */
export function describeHttpFailure(code: string | null, status: number): string {
  if (code === null || code === undefined) {
    if (status === 404) return "服务端返回 404 且没有 JSON 信封：未知路由（协议错误，不是业务错误）。";
    return "服务端返回了非协议响应（HTTP " + String(status) + "）。";
  }
  return t.six.serverCode + ": " + code + "（HTTP " + String(status) + "）";
}

/** Connect-form failures (POST /api/accounts/imap), by code (checklist §2). */
export function describeConnectFailure(code: string | null, status: number): string {
  switch (code) {
    case "imap-auth-failed":
      return t.onboarding.errorAuthFailed;
    case "imap-unreachable":
      return t.onboarding.errorUnreachable;
    case "provider-not-configured":
      return t.onboarding.errorNotConfigured;
    case "account-exists":
      return t.onboarding.errorExists;
    case "missing-field":
    case "missing-body":
      return t.onboarding.errorMissingField;
    default:
      return status === 401 ? t.onboarding.errorAuthFailed : t.onboarding.errorUnknown;
  }
}
/* ======================================================================== */
/* M2 write paths                                                           */
/* ======================================================================== */

/**
 * Codes that mean "this server/this message cannot do that", not "it broke".
 *
 * The distinction is the whole point of checklist §2 and of the lead's hard
 * constraint: 409 archive-unavailable must read 服务器不支持, never
 * 操作失败: something went wrong. Retrying cannot fix either of them, so
 * neither offers 重试 here.
 */
export const WRITE_UNAVAILABLE: Record<string, { title: string; detail?: string }> = {
  "archive-unavailable": {
    title: t.m2.write.notSupported,
    detail: "服务端返回 409 archive-unavailable：这个账号没有可用的归档文件夹（或能力探测已判定 false）。重试不会变。",
  },
  "delete-unavailable": {
    title: t.m2.write.notSupported,
    detail: "服务端返回 409 delete-unavailable：这个账号没有废纸篓文件夹。重试不会变。",
  },
  "not-in-trash": {
    title: t.m2.write.notInTrash,
    detail: "服务端返回 409 not-in-trash：只有废纸篓里的邮件才能彻底删除。",
  },
  "provider-not-configured": {
    title: "邮箱授权不可用",
    detail: "服务端返回 503 provider-not-configured：这个账号的凭据解不开（合成账号就是这样），所以远端操作一定失败。",
  },
};

/** Undo has three *different* failures and they must not share a sentence. */
export const UNDO_COPY: Record<string, string> = {
  "already-undone": t.m2.write.alreadyUndone,
  "action-expired": t.m2.write.actionExpired,
  "not-undoable": t.m2.write.notUndoable,
  "unknown-action": "服务端找不到这个动作（可能是另一个窗口撤销的）",
  "undo-failed": "服务端撤销失败（远端没有接受这次反向操作）",
};

/** Human sentence for a write failure, by code and status. */
export function describeWriteFailure(code: string | null, status: number): string {
  if (code && WRITE_UNAVAILABLE[code]) {
    const entry = WRITE_UNAVAILABLE[code];
    return entry.detail ?? entry.title;
  }
  if (code && UNDO_COPY[code]) return UNDO_COPY[code];
  if (code) return t.six.serverCode + ": " + code + "（HTTP " + String(status) + "）";
  return describeHttpFailure(null, status);
}

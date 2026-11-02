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
    detail: "服务端返回 503 provider-not-configured：这个账号的凭据解不开，或者这版构建没有接邮箱。重试不会变。",
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
  return (
    codeSentenceFor(code) ??
    t.six.serverCode + ": " + code + "（HTTP " + String(status) + "）"
  );
}

/**
 * Sentences for backend codes that are neither "unavailable" nor a write
 * failure: malformed requests (front-end bugs), internal failures and the
 * protocol-level answers.
 *
 * Every code `respond::error` can emit must have an entry somewhere in this
 * file - `errors.test.ts` carries the list from the Rust routes and fails when
 * one is missing, so a new server code cannot silently reach the user as
 * "服务端返回值: foo".
 */
const CODE_SENTENCES: Record<string, string> = {
  "account-exists": "这个邮箱已经连接过了；重复连接不会覆盖现有凭据。",
  "ai-error": "模型回答了，但答的不是能用的东西（502）。重试可能有用；一直失败就是 bug。",
  "attachment-not-found": "这封邮件里没有这个附件（可能在服务器上已被替换或删除）。",
  "draft-unreadable": "这封草稿在本地解不开（密钥变了或数据损坏），只能重新生成。",
  "empty-actionIds": "批量请求没有带动作 id（前端 bug）。",
  "empty-remoteIds": "批量请求没有带邮件 id（前端 bug）。",
  "encoding-failed": "服务端编码响应失败（协议错误，正常不该出现）。",
  "imap-auth-failed": t.onboarding.errorAuthFailed,
  "imap-unreachable": t.onboarding.errorUnreachable,
  "internal-error": "服务端内部错误（500）。重试可能有用；一直失败就是 bug。",
  "invalid-body": "请求体不是合法 JSON（前端 bug）。",
  "malformed-action-id": "动作 id 格式不对（前端 bug）。",
  "malformed-attachmentId": "附件 id 格式不对（前端 bug）。",
  "malformed-before": "before 参数格式不对（前端 bug）。",
  "malformed-decision": "决定的取值不合法（前端 bug）。",
  "malformed-pinned": "pinned 参数不是布尔值（前端 bug）。",
  "malformed-remoteId": "邮件 id 格式不对（前端 bug）。",
  "message-gone": "这封邮件在服务器上已经不在了（可能已被删除或移走）。",
  "missing-body": "请求体缺失（前端 bug）。",
  "missing-field": "缺少必填字段（前端 bug）。",
  "provider-auth-failed": "邮箱授权被服务器拒绝（401）。重新连接这个账号即可。",
  "provider-unreachable": "连不上邮箱服务器（502）。这是网络或服务端问题，可以重试。",
  "uidplus-missing": "这个邮箱服务器不支持 UIDPLUS，不能彻底删除；只能移入垃圾箱。",
  "unknown-before": "before 指向的动作不存在（可能已被另一个窗口清掉）。",
  "unknown-stack": "没有这个 stack 参数（前端 bug）。",
};

/** The human sentence for a backend code, or null when the dictionary lacks one. */
export function codeSentenceFor(code: string): string | null {
  const common = COMMON_UNAVAILABLE[code];
  if (common) return common.detail ?? common.title;
  const write = WRITE_UNAVAILABLE[code];
  if (write) return write.detail ?? write.title;
  const undo = UNDO_COPY[code];
  if (undo) return undo;
  return CODE_SENTENCES[code] ?? null;
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
  "provider-not-configured": {
    title: "邮箱授权不可用",
    detail: "服务端返回 503 provider-not-configured：这个账号的凭据解不开（合成账号就是这样），所以远端操作一定失败。",
  },
  // The send paths (R3.5b). Every one of them is refused BEFORE the message
  // reaches the SMTP server: a rejected request never sends half a mail.
  "malformed-recipient": {
    title: "收件人地址不合法（400）",
    detail: "服务端在发信前就拒了：收件人不是一个合法地址。改一下再发。",
  },
  "malformed-attachment": {
    title: "附件解不开（400）",
    detail: "服务端在发信前就拒了：附件数据不是合法的 base64，或者缺了字段。",
  },
  "malformed-request-id": {
    title: "请求 id 不合法（400）",
    detail: "服务端要求 requestId 是一个 UUID（用来保证一封只发一次）。这是前端 bug。",
  },
  "malformed-compose": {
    title: "写信请求不完整（400）",
    detail: "新邮件至少要有收件人和正文。",
  },
  "malformed-forward": {
    title: "转发请求不合法（400）",
    detail: "转发要一份收件人数组，而且不能自己再带附件（原信会被整个带过去）。",
  },
  "malformed-body": {
    title: "请求体不合法（400）",
    detail: "服务端没有从请求体里读到它要的东西。这是前端 bug。",
  },
  "send-in-flight": {
    title: "这封还在发（409）",
    detail: "同一个 requestId 已经有一封在发。稍等一下再试，不要重复点发送。",
  },
  "smtp-auth-failed": {
    title: "发信服务器拒绝了授权（401）",
    detail: "服务端返回 401 smtp-auth-failed：这个账号的邮箱授权码不被发信服务器接受。重新连接这个账号。",
  },
  "smtp-send-failed": {
    title: "信没发出去（502）",
    detail: "服务端返回 502 smtp-send-failed：网络或发信服务器的问题。重试可能有用。",
  },
  "forward-original-unavailable": {
    title: "拿不到原信（502）",
    detail: "转发要把原信整个带过去，但服务端没能取到原文；转发一封残缺的信比不转发更糟。",
  },
  "attachment-too-large": {
    title: "附件太大（413）",
    detail: "单个附件最大 25 MB，一次最多 48 MB。",
  },
  "unknown-message": {
    title: "服务端找不到这封邮件（404）",
    detail: "邮件已经被删掉，或者这个 id 属于别的账号。",
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
  if (code) {
    const sentence = codeSentenceFor(code);
    if (sentence) return sentence;
  }
  return describeHttpFailure(null, status);
}

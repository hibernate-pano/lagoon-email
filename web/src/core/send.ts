/**
 * The send path, as the front-end sees it (R3.5b).
 *
 * Three routes, three shapes, one rule: **one requestId, one delivery.** The
 * server keeps a row per requestId, so a replay answers the first result
 * instead of sending a second mail. That rule decides everything here:
 *
 *   - the requestId is minted per *attempt*, and it survives a retry only when
 *     the previous attempt's outcome is unknown (see {@link requestIdFor});
 *   - a retry after a refusal gets a fresh id, because the server remembers a
 *     failed attempt and replays its error instead of trying again;
 *   - a retry after "no answer" keeps the id, because the mail may already be
 *     out there and a new id would send a second copy.
 *
 * The three body shapes are the contract's, not this file's opinion
 * (docs/api-contract.md v0.2): compose takes one recipient *string*, reply and
 * forward take a recipient *list*. The list is never split here - the server
 * splits each entry itself, so `"Zhang, Wei" <wei@example.com>` survives as one
 * address.
 */
import { apiCall } from "./api";
import { describeHttpFailure, WRITE_UNAVAILABLE } from "./errors";
import type { WriteFailure } from "./writes";
import { t } from "../l10n/zh";

export type SendMode = "reply" | "compose" | "forward";

/** One attachment on its way out. */
export interface SendAttachment {
  filename: string;
  mimeType: string;
  dataBase64: string;
}

export interface SendForm {
  to: string;
  cc: string;
  bcc: string;
  subject: string;
  body: string;
  attachments: SendAttachment[];
}

/** The message being replied to or forwarded. */
export interface SendOriginal {
  remoteId: string;
  fromAddress: string;
  fromName?: string | null;
  subject?: string | null;
  receivedAt: string;
  /** The original's date, already formatted for humans. */
  when: string;
  /** The original's plain text, if there is any. */
  text: string;
}

/** The server's ceiling, copied from routes_send.rs. */
export const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024;
export const MAX_TOTAL_ATTACHMENT_BYTES = 48 * 1024 * 1024;

/** How much of the original a reply quotes. */
const QUOTE_LIMIT = 3000;

/* ------------------------------------------------------------------ draft --- */

export function emptyForm(): SendForm {
  return { to: "", cc: "", bcc: "", subject: "", body: "", attachments: [] };
}

/** The starting point for a mode: what the user sees before typing anything. */
export function draftFor(mode: SendMode, original?: SendOriginal): SendForm {
  const form = emptyForm();
  if (mode === "reply" && original) {
    form.to = original.fromAddress;
    form.subject = replySubject(original.subject);
    form.body = quotedReply(original);
  }
  if (mode === "forward" && original) {
    form.subject = forwardSubject(original.subject);
  }
  return form;
}

/**
 * Whether closing the composer would throw away something the user wrote.
 *
 * Compared against the form the composer opened with, not against "empty": a
 * reply already carries the quoted original and a subject, and none of that is
 * text the user would miss.
 */
export function hasDraftChanges(initial: SendForm, current: SendForm): boolean {
  return (
    current.to.trim() !== initial.to.trim() ||
    current.cc.trim() !== initial.cc.trim() ||
    current.bcc.trim() !== initial.bcc.trim() ||
    current.subject.trim() !== initial.subject.trim() ||
    current.body.trim() !== initial.body.trim() ||
    current.attachments.length !== initial.attachments.length
  );
}

/** "Re: 报价", but not "Re: Re: 报价". */function replySubject(subject: string | null | undefined): string {
  const value = (subject ?? "").trim();
  if (value === "") return "";
  if (/^(re|回复|答复)\s*[:：]/i.test(value)) return value;
  return "Re: " + value;
}

/** "Fwd: 报价", but not "Fwd: Fwd: 报价". */
function forwardSubject(subject: string | null | undefined): string {
  const value = (subject ?? "").trim();
  if (value === "") return "Fwd:";
  if (/^(fwd|fw|转发)\s*[:：]/i.test(value)) return value;
  return "Fwd: " + value;
}

/**
 * The quoted original under the reply.
 *
 * Only what is actually there: no text means no quote, never an invented one.
 * The header line alone keeps the body non-empty, which matters because the
 * server refuses an empty reply with 400 malformed-body.
 */
export function quotedReply(original: SendOriginal): string {
  const who = original.fromName?.trim()
    ? `${original.fromName.trim()} <${original.fromAddress}>`
    : original.fromAddress;
  const header = t.compose.quotedHeader(original.when, who);
  const text = original.text.trim();
  if (text === "") return header + "\n";
  const clipped = text.length > QUOTE_LIMIT ? text.slice(0, QUOTE_LIMIT) + "…" : text;
  const quoted = clipped
    .split("\n")
    .map((line) => "> " + line)
    .join("\n");
  return header + "\n" + quoted + "\n";
}

/* ------------------------------------------------------------- validation --- */

export type SendField = "to" | "cc" | "bcc" | "body";

export type SendValidation = { ok: true } | { ok: false; field: SendField; reason: string };

/**
 * The check that saves a round trip.
 *
 * It is deliberately thin: the server is the authority on what an address is
 * (it understands display names and quoted commas, this does not). It only
 * catches the two things the user can see are wrong - a missing recipient and
 * an empty reply - and a recipient with no "@" in it at all.
 */
export function validateForm(mode: SendMode, form: SendForm): SendValidation {
  const to = form.to.trim();
  if (mode !== "reply" && to === "") {
    return { ok: false, field: "to", reason: t.compose.needRecipient };
  }
  if (to !== "" && !to.includes("@")) {
    return { ok: false, field: "to", reason: t.compose.badRecipient };
  }
  for (const field of ["cc", "bcc"] as const) {
    const value = form[field].trim();
    if (value !== "" && !value.includes("@")) {
      return { ok: false, field, reason: t.compose.badRecipient };
    }
  }
  if (mode === "reply" && form.body.trim() === "") {
    return { ok: false, field: "body", reason: t.compose.needBody };
  }
  return { ok: true };
}

/* ------------------------------------------------------------------ body --- */

export interface SendBody {
  body: string;
  to?: string[] | string;
  cc?: string;
  bcc?: string;
  subject?: string;
  requestId: string;
  attachments?: SendAttachment[];
}

/** The JSON body of a send request, in the shape its route accepts. */
export function buildSendBody(mode: SendMode, form: SendForm, requestId: string): SendBody {
  const to = form.to.trim();
  const cc = form.cc.trim();
  const bcc = form.bcc.trim();
  const body: SendBody = {
    body: form.body,
    subject: form.subject,
    requestId,
  };
  if (cc !== "") body.cc = cc;
  if (bcc !== "") body.bcc = bcc;

  if (mode === "compose") {
    body.to = to;
    if (form.attachments.length > 0) body.attachments = form.attachments;
    return body;
  }
  // Reply and forward take a list. One entry holding the whole field: the
  // server splits each entry, so the user's commas and quotes survive.
  if (mode === "forward") {
    body.to = to === "" ? [] : [to];
    // A forwarded mail IS the attachment; a second file makes two different
    // things out of one message, and the server refuses it (malformed-forward).
    return body;
  }
  if (to !== "") body.to = [to];
  if (form.attachments.length > 0) body.attachments = form.attachments;
  return body;
}

/* ------------------------------------------------------------- endpoints --- */

export function sendPath(mode: SendMode, remoteId: string): string {
  const id = encodeURIComponent(remoteId);
  if (mode === "compose") return "/api/compose/send";
  if (mode === "forward") return "/api/messages/" + id + "/forward";
  return "/api/messages/" + id + "/send";
}

/* --------------------------------------------------------------- sending --- */

/**
 * How a send ended.
 *
 * `refused` means the server answered and the mail did not go out.
 * `unknown` means there was no answer at all: the mail may or may not be out
 * there, and the only safe retry is the same requestId.
 * `inflight` means another request with this id is on the wire.
 */
export type SendResult =
  | { kind: "sent"; providerMessageId?: string }
  | { kind: "refused"; failure: WriteFailure }
  | { kind: "unknown"; failure?: WriteFailure; message: string }
  | { kind: "inflight"; failure: WriteFailure };

export async function sendMail(
  mode: SendMode,
  remoteId: string,
  accountId: string,
  form: SendForm,
  requestId: string,
): Promise<SendResult> {
  const result = await apiCall<{ ok: boolean; providerMessageId?: string }>({
    method: "POST",
    path: sendPath(mode, remoteId),
    query: { accountId },
    body: buildSendBody(mode, form, requestId),
  });
  if (result.kind === "fail") {
    // Never reached the server (or no answer in time). The mail may or may
    // not be out there; the caller keeps the same requestId.
    return { kind: "unknown", message: result.message };
  }
  if (result.kind === "http") {
    const failure = describeSendFailure(result.code, result.status);
    if (result.code === "send-in-flight") {
      return { kind: "inflight", failure };
    }
    return { kind: "refused", failure };
  }
  return { kind: "sent", providerMessageId: result.data?.providerMessageId };
}

/* ----------------------------------------------------------------- retry --- */

/** What the previous attempt was, and how it ended. */
export interface SendAttempt {
  requestId: string;
  fingerprint: string;
  outcome: "refused" | "unknown" | "inflight";
}

/**
 * Which requestId this attempt must use.
 *
 * - The content is the same and the last outcome is unknown: reuse the id.
 *   The server replays the first result, so a retry cannot send twice.
 * - The content is the same and the last outcome was a refusal: a fresh id.
 *   The server remembers the failed attempt and replays its error, so reusing
 *   the id would reproduce the same failure forever.
 * - The content changed: a fresh id (it is a different mail) - and if the last
 *   outcome was unknown, the previous mail may still arrive, so the caller
 *   warns.
 */
export function requestIdFor(
  last: SendAttempt | null,
  fingerprint: string,
  mint: () => string,
): { requestId: string; warnDuplicate: boolean } {
  const uncertain = last !== null && (last.outcome === "unknown" || last.outcome === "inflight");
  if (last !== null && last.fingerprint === fingerprint) {
    if (uncertain) return { requestId: last.requestId, warnDuplicate: false };
    return { requestId: mint(), warnDuplicate: false };
  }
  return { requestId: mint(), warnDuplicate: uncertain };
}

/** How much of each end of an attachment's base64 the fingerprint samples. */
const FINGERPRINT_SAMPLE = 2048;

/**
 * A cheap content digest for one attachment.
 *
 * Length alone collides: replacing `report.pdf` with a corrected `report.pdf`
 * of the same size left the fingerprint unchanged, so a retry after an
 * "unknown" outcome reused the requestId and the server replayed the first
 * (old) result - the corrected mail was never sent. Sampling both ends and
 * hashing them catches a different file without walking 25 MB of base64 on
 * every keystroke.
 */
function attachmentDigest(attachment: SendAttachment): string {
  const data = attachment.dataBase64;
  const head = data.slice(0, FINGERPRINT_SAMPLE);
  const tail = data.slice(Math.max(0, data.length - FINGERPRINT_SAMPLE));
  const sample = head + tail;
  let hash = 0x811c9dc5; // FNV-1a, 32 bit
  for (let index = 0; index < sample.length; index += 1) {
    hash ^= sample.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return data.length + ":" + hash.toString(16);
}

/** What the content is, for the fingerprint above. */
export function fingerprintOf(form: SendForm): string {
  return JSON.stringify([
    form.to.trim(),
    form.cc.trim(),
    form.bcc.trim(),
    form.subject,
    form.body,
    form.attachments.map(
      (a) => a.filename + ":" + a.mimeType + ":" + attachmentDigest(a),
    ),
  ]);
}

/* --------------------------------------------------------------- request --- */

/**
 * A v4 UUID, in the shape the server's strict parser accepts.
 *
 * `crypto.randomUUID` needs a secure context; the Tauri webview has one, but
 * the fallback keeps the app working in a plain browser tab (where the
 * WebCrypto `getRandomValues` is available even without a secure context).
 */
export function newRequestId(): string {
  const source = globalThis.crypto;
  if (source && typeof source.randomUUID === "function") {
    return source.randomUUID();
  }
  const bytes = new Uint8Array(16);
  source.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return (
    hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" +
    hex.slice(16, 20) + "-" + hex.slice(20)
  );
}

/* --------------------------------------------------------------- failure --- */

/** The sentence for a send failure: title + detail, both already localised. */
export function describeSendFailure(code: string | null, status: number): WriteFailure {
  const entry = code ? WRITE_UNAVAILABLE[code] : undefined;
  return {
    ok: false,
    kind: "server",
    code,
    status,
    message: entry?.detail ?? entry?.title ?? describeHttpFailure(code, status),
  };
}

/** The headline for a refused send. Never the generic fallback when the code is known. */
export function sendFailureTitle(code: string | null): string {
  const entry = code ? WRITE_UNAVAILABLE[code] : undefined;
  return entry?.title ?? t.compose.failedTitle;
}

/* ------------------------------------------------------------ attachment --- */

/**
 * Base64, in chunks.
 *
 * `String.fromCharCode(...bytes)` with a 25 MB attachment blows the argument
 * limit, so the bytes go through in 32 KB pieces.
 */
export function bytesToBase64(bytes: Uint8Array): string {
  const chunk = 0x8000;
  let binary = "";
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

/** How many bytes a base64 string decodes to. */
export function base64ByteLength(encoded: string): number {
  if (encoded.length === 0) return 0;
  const padding = encoded.endsWith("==") ? 2 : encoded.endsWith("=") ? 1 : 0;
  return (encoded.length * 3) / 4 - padding;
}

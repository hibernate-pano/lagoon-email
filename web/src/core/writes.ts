/**
 * The M2 write endpoints, one function each, with the failure taxonomy the UI
 * needs to react to (not just to print).
 *
 * Taxonomy, taken from recon/server-contract.md §2 and the captured fixtures:
 *
 *   capability  — 409 archive-unavailable / delete-unavailable / not-in-trash,
 *                 503 provider-not-configured. The answer is final: do NOT retry,
 *                 do NOT say "something went wrong".
 *   conflict    — already-undone / action-expired / not-undoable / send-in-flight.
 *                 Each has its own sentence; collapsing them into one is exactly
 *                 what a user cannot act on.
 *   gone        — 410 message-gone / action-expired on a message.
 *   notfound    — 404 unknown-account / unknown-action.
 *   unauthorized— 401 (token / provider auth).
 *   transport   — never reached the server (ok:false from api()).
 *   server      — everything else (5xx, malformed).
 *
 * Every function returns a value, never throws: an optimistic mutation has to be
 * able to roll back on any outcome, including a thrown one.
 */
import { apiCall } from "./api";
import { describeWriteFailure } from "./errors";
import type {
  ActionsResponse,
  BulkResponse,
  EmptyTrashResponse,
  PurgeResponse,
  StateChangeResponse,
  UndoBulkItem,
  UndoBulkResponse,
  UndoResponse,
} from "./types";

export type WriteFailureKind =
  | "capability"
  | "conflict"
  | "gone"
  | "notfound"
  | "unauthorized"
  | "transport"
  | "server";

export interface WriteFailure {
  ok: false;
  kind: WriteFailureKind;
  code: string | null;
  status: number;
  /** Sentence for the banner; already localised. */
  message: string;
}

export type WriteResult = { ok: true; actionId?: number; purged?: number } | WriteFailure;

const CAPABILITY_CODES = new Set([
  "archive-unavailable",
  "delete-unavailable",
  "not-in-trash",
  "sent-unavailable",
  "provider-not-configured",
]);

const CONFLICT_CODES = new Set([
  "already-undone",
  "action-expired",
  "not-undoable",
  "send-in-flight",
  "account-exists",
]);

const GONE_CODES = new Set(["message-gone"]);
const NOTFOUND_CODES = new Set(["unknown-account", "unknown-action", "unknown-message"]);

export function classifyFailure(code: string | null, status: number): WriteFailureKind {
  if (code && CAPABILITY_CODES.has(code)) return "capability";
  if (code && CONFLICT_CODES.has(code)) return "conflict";
  if (code && GONE_CODES.has(code)) return "gone";
  if (code && NOTFOUND_CODES.has(code)) return "notfound";
  if (status === 401 || code === "api-unauthorized") return "unauthorized";
  return "server";
}

function transportFailure(message: string): WriteFailure {
  return { ok: false, kind: "transport", code: null, status: 0, message };
}

function failure(code: string | null, status: number, kind?: WriteFailureKind): WriteFailure {
  return {
    ok: false,
    kind: kind ?? classifyFailure(code, status),
    code,
    status,
    message: describeWriteFailure(code, status),
  };
}

function messagePath(remoteId: string, suffix: string): string {
  return "/api/messages/" + encodeURIComponent(remoteId) + "/" + suffix;
}

async function post<T>(
  path: string,
  query: Record<string, string | number | boolean | undefined>,
  body?: unknown,
): Promise<{ kind: "ok"; data: T } | { kind: "http"; code: string | null; status: number } | { kind: "fail"; message: string }> {
  const result = await apiCall<T>({ method: "POST", path, query, body });
  if (result.kind === "ok") return { kind: "ok", data: result.data };
  if (result.kind === "http") return { kind: "http", code: result.code, status: result.status };
  return { kind: "fail", message: result.message };
}

/* ------------------------------------------------------------------ single */

export type SingleVerb = "archive" | "unarchive" | "delete" | "restore" | "purge";

export async function singleAction(
  verb: SingleVerb,
  remoteId: string,
  accountId: string,
): Promise<WriteResult> {
  const result = await post<StateChangeResponse | PurgeResponse>(messagePath(remoteId, verb), { accountId });
  if (result.kind === "fail") return transportFailure(result.message);
  if (result.kind === "http") return failure(result.code, result.status);
  const data = result.data;
  const actionId = "actionId" in data ? data.actionId : undefined;
  const purged = "purged" in data ? data.purged : undefined;
  return { ok: true, actionId, purged };
}

export async function setPinned(remoteId: string, accountId: string, pinned: boolean): Promise<WriteResult> {
  const result = await post<StateChangeResponse>(messagePath(remoteId, "pin"), { accountId, pinned });
  if (result.kind === "fail") return transportFailure(result.message);
  if (result.kind === "http") return failure(result.code, result.status);
  return { ok: true, actionId: result.data.actionId };
}

/**
 * POST /read with record=true — this one writes an audit row *and* asks the
 * server to set \\Seen on the mailbox. M1 deliberately left it off (config.ts);
 * M2 turns it on because the audit row is what makes it undoable.
 */
export async function setRead(
  remoteId: string,
  accountId: string,
  isRead: boolean,
): Promise<WriteResult> {
  const result = await post<StateChangeResponse | null>(messagePath(remoteId, "read"), {
    accountId,
    isRead,
    record: "true",
  });
  if (result.kind === "fail") return transportFailure(result.message);
  if (result.kind === "http") return failure(result.code, result.status);
  const actionId = result.data?.actionId;
  return { ok: true, actionId };
}

/* -------------------------------------------------------------------- bulk */

export interface BulkResult {
  ok: true;
  items: { remoteId: string; ok: boolean; actionId?: number; errorCode?: string }[];
  truncatedCount?: number;
}

export async function bulkAction(
  verb: "archive" | "delete",
  remoteIds: string[],
  accountId: string,
): Promise<BulkResult | WriteFailure> {
  const path = verb === "archive" ? "/api/archive-bulk" : "/api/delete-bulk";
  const result = await post<BulkResponse>(path, { accountId }, { remoteIds });
  if (result.kind === "fail") return transportFailure(result.message);
  // A bulk endpoint can still fail as a whole (409 archive-unavailable) when the
  // capability is settled false — that is a capability answer, not a partial one.
  if (result.kind === "http") return failure(result.code, result.status);
  return {
    ok: true,
    items: result.data.items ?? [],
    truncatedCount: result.data.truncatedCount ?? undefined,
  };
}

export async function emptyTrash(accountId: string): Promise<WriteResult> {
  const result = await post<EmptyTrashResponse>("/api/trash/empty", { accountId });
  if (result.kind === "fail") return transportFailure(result.message);
  if (result.kind === "http") return failure(result.code, result.status);
  return { ok: true, purged: result.data.purged };
}

/* -------------------------------------------------------------------- undo */

export async function undoAction(actionId: number, accountId: string): Promise<WriteResult> {
  const result = await post<UndoResponse>("/api/actions/" + String(actionId) + "/undo", { accountId });
  if (result.kind === "fail") return transportFailure(result.message);
  if (result.kind === "http") return failure(result.code, result.status);
  return { ok: true };
}

export async function undoBulk(
  actionIds: number[],
  accountId: string,
): Promise<{ ok: true; items: UndoBulkItem[] } | WriteFailure> {
  const result = await post<UndoBulkResponse>("/api/actions/undo-bulk", { accountId }, { actionIds });
  if (result.kind === "fail") return transportFailure(result.message);
  if (result.kind === "http") return failure(result.code, result.status);
  return { ok: true, items: result.data.items ?? [] };
}

/* ----------------------------------------------------------------- history */

export async function fetchActions(
  accountId: string,
  options: { limit?: number; before?: number } = {},
): Promise<ActionsResponse | WriteFailure> {
  const result = await apiCall<ActionsResponse>({
    method: "GET",
    path: "/api/actions",
    query: { accountId, limit: options.limit ?? 50, before: options.before },
  });
  if (result.kind === "ok") return result.data;
  if (result.kind === "http") return failure(result.code, result.status);
  return failure(null, 0, "transport");
}

/* ------------------------------------------------------------- capability */

/**
 * v3's gate rule, ported exactly (MailCapabilities.swift:121-156):
 * only a settled false closes the gate; nil (not probed) reads as *allowed* and
 * the server's 409 is the authority.
 */
export function allows(gate: boolean | null | undefined): boolean {
  return gate !== false;
}

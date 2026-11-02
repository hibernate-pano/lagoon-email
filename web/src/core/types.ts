/**
 * Wire types, verbatim from v4/recon/server-contract.md §3.1 and the Swift
 * structs it cites. camelCase everywhere; dates are ISO-8601 strings.
 *
 * Rule inherited from the contract: a missing field is *unknown*, never false
 * and never 0. Hence the many optional / nullable fields below — collapsing
 * them to defaults is exactly the "data-loss-shaped bug" MailCapabilities.swift
 * documents at length.
 */

export type ISO8601 = string;

export interface MessageHeader {
  id: string;
  accountId: string;
  remoteId: string;
  threadId?: string | null;
  fromAddress: string;
  fromName?: string | null;
  subject?: string | null;
  snippet?: string | null;
  receivedAt: ISO8601;
  isRead: boolean;
  isArchived: boolean;
  isDeleted: boolean;
  isPinned: boolean;
  isSent: boolean;
  messageIdHeader?: string | null;
  inReplyTo?: string | null;
  references?: string | null;
}

/** Three states by construction: true / false / not-probed (nil). */
export type TriBool = boolean | null | undefined;

export interface MailCapabilities {
  archiveFolder?: TriBool;
  idle?: boolean;
  move?: boolean;
  serverSnippet?: boolean;
  uidplus?: TriBool;
  sentFolder?: TriBool;
  trashFolder?: TriBool;
  archiveFolderName?: string | null;
}

export type SyncStatus = "ok" | "degraded" | "needsReconnect" | "error" | "accountMissing";

export interface SyncHealth {
  status: SyncStatus;
  lastSyncAt?: ISO8601 | null;
  lastError?: string | null;
}

export interface ConnectedAccount {
  id: string;
  provider: string;
  email: string;
  isActive: boolean;
  unreadCount: number;
  syncHealth: SyncHealth;
  capabilities: MailCapabilities;
}

export interface SyncCursor {
  accountId: string;
  lastFetchedAt?: ISO8601 | null;
  totalUnread: number;
}

export interface SyncResponse {
  cursor: SyncCursor;
  messages: MessageHeader[];
  /** Absent = unknown (the server did not say), never 0. */
  totalCount?: number | null;
}

export type AttachmentDisposition = "attachment" | "inline";

export interface Attachment {
  id: string;
  filename?: string | null;
  mimeType: string;
  size: number;
  contentId?: string | null;
  disposition: AttachmentDisposition;
}

export interface MessageBody {
  remoteId: string;
  subject?: string | null;
  fromAddress: string;
  fromName?: string | null;
  toAddress?: string | null;
  receivedAt: ISO8601;
  text: string;
  html?: string | null;
  attachments: Attachment[];
  hasMore: boolean;
  to: string[];
  cc: string[];
}

export type BriefingGroupId =
  | "needsReply"
  | "awaitingReply"
  | "safeToArchive"
  | "subscriptionNoise"
  | "pinned";

export interface BriefingItem {
  message: MessageHeader;
  group: BriefingGroupId;
  reasonCode?: string | null;
}

export interface BriefingResponse {
  items: BriefingItem[];
  /** Messages inside the window that did not fit under the cap. */
  omittedCount?: number | null;
  /** Unread mail older than the window — the count, not the rows. */
  backlogCount?: number | null;
}

export type AdvisedAction = "reply" | "wait" | "archive" | "delete" | "unsubscribe" | "remind" | "nothing";
export type AdviceConfidence = "high" | "medium" | "low";
export type AdviceDecision = "pending" | "accepted" | "dismissed";

export interface Advice {
  action: AdvisedAction;
  category?: string | null;
  confidence: AdviceConfidence;
  rationale?: string | null;
  dueText?: string | null;
}

export interface AdviceRecord {
  id: number;
  accountId: string;
  remoteId: string;
  advice: Advice;
  source: string;
  model?: string | null;
  decision: AdviceDecision;
  createdAt: ISO8601;
  decidedAt?: ISO8601 | null;
}

export interface AdviceResponse {
  advice: AdviceRecord[];
}

export interface FolderCountResponse {
  counts: { id: string; count: number }[];
}

export interface SearchResponse {
  results: MessageHeader[];
  query: string;
  totalCount?: number | null;
  truncated?: boolean | null;
  bodyScanSkipped?: boolean | null;
  bodyScanLimit?: number | null;
}

export interface AiStatus {
  configured: boolean;
  creditExhausted: boolean;
  circuitOpen: boolean;
}

export interface StoreNotice {
  id: string;
  createdAt: ISO8601;
  detail?: string | null;
}

export interface StoreNoticesResponse {
  notices: StoreNotice[];
}

export interface InlineImagesResponse {
  /** cid (lowercase, no angle brackets) -> base64 bytes. */
  images: Record<string, string>;
}

export interface MessageSummary {
  remoteId: string;
  summary: string;
  actionItems: string[];
  provider?: string | null;
}

/** GET /api/sent — its own shape: the sent folder is a different route. */
export interface SentResponse {
  messages: MessageHeader[];
  totalCount: number;
  /** How many rows this response refreshed from the server (wire_r2.rs). */
  refreshedFromServer?: number;
  staleReason?: string | null;
}

/** The one error shape the server ever returns: {"error":"<stable code>"}. */
export interface ApiErrorBody {
  error: string;
}
/* ---- M2 write paths (v4/docs/api-contract.md; shapes cross-checked against
   v4/tests/contract/fixtures/fixtures.json) ---------------------------------- */

/** POST /api/messages/:id/{archive,delete,unarchive,restore,pin,read} */
export interface StateChangeResponse {
  ok: boolean;
  remoteId: string;
  remote?: boolean;
  actionId?: number;
}

/** POST /api/messages/:id/purge — irreversible, and deliberately carries no actionId. */
export interface PurgeResponse {
  ok: boolean;
  remoteId: string;
  purged: number;
}

/** One entry of a bulk response: the server reports per-message success. */
export interface BulkItem {
  remoteId: string;
  ok: boolean;
  actionId?: number;
  errorCode?: string;
}

/** POST /api/archive-bulk | /api/delete-bulk */
export interface BulkResponse {
  items: BulkItem[];
  truncatedCount?: number | null;
}

/** POST /api/trash/empty */
export interface EmptyTrashResponse {
  ok: boolean;
  remoteId: string;
  purged: number;
}

export type ActionKind =
  | "archive"
  | "read"
  | "pin"
  | "unpin"
  | "unsubscribe"
  | "classify_override"
  | "draft_create"
  | "send"
  | "undo"
  | "delete"
  | "purge";

/** One audit-log row of GET /api/actions. */
export interface ActionRecord {
  id: number;
  accountId: string;
  kind: ActionKind | string;
  payload: Record<string, string>;
  createdAt: ISO8601;
  expiresAt?: ISO8601 | null;
}

export interface ActionsResponse {
  actions: ActionRecord[];
  totalCount?: number | null;
  hasMore?: boolean | null;
}

/** POST /api/actions/:id/undo */
export interface UndoResponse {
  ok: boolean;
  undone: number;
}

/** POST /api/actions/undo-bulk */
export interface UndoBulkItem {
  actionId: number;
  ok: boolean;
  errorCode?: string;
}

export interface UndoBulkResponse {
  items: UndoBulkItem[];
  undone: number;
}

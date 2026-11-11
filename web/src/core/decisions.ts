/**
 * Turning a queue of suggestions into the few decisions a person can hold in
 * their head.
 *
 * This is the whole product idea in one file. 430 mails do not become 8 cards
 * because the UI is pretty; they become 8 cards because this function groups
 * them, and the grouping is the thing that was missing.
 *
 * Two card kinds:
 *
 *   action     - mails a rule or the model judged the same way (`archive`,
 *                `delete`). One click settles every mail in the group.
 *   sender     - one address that writes a lot (>= `SENDER_THRESHOLD`), even
 *                when the judgments differ. Killing spam is a sender-level act,
 *                not a message-level one.
 *
 * Everything else - `reply`, `wait`, `remind`, `unsubscribe`, `nothing` - is
 * deliberately *not* a card: those need the user's own words or a trip to the
 * publisher's page, and a batch button would be a lie. They go in a separate
 * list so they are not lost either.
 *
 * Pure functions only: no fetch, no React. The grouping is the part worth
 * testing, so it does not live inside a component.
 */
import type {
  AdviceRecord,
  AdvisedAction,
  AdviceConfidence,
  MessageHeader,
  SenderSummary,
} from "./types";

/** A sender needs at least this many mails waiting to earn its own card. */
export const SENDER_THRESHOLD = 10;

/** How many cards the board shows before folding the rest into one row. */
export const VISIBLE_CARDS = 6;

/** The actions a card may offer to execute. */
export type ExecutableAction = "archive" | "delete";

const EXECUTABLE: ReadonlySet<AdvisedAction> = new Set<AdvisedAction>(["archive", "delete"]);

export interface DecisionGroup {
  /** Stable key, so React and the URL round-trip the same group. */
  id: string;
  kind: "action" | "sender";
  action: ExecutableAction;
  /** What the card says it will do, in the user's language. */
  label: string;
  /** The mails this card would act on. */
  remoteIds: string[];
  /** Cents-of-a-second sample for the card: the first few, newest first. */
  samples: { remoteId: string; subject: string | null; fromAddress: string }[];
  /** How many of the mails came from each layer. `heuristic + ai === total`. */
  bySource: { heuristic: number; ai: number };
  /** How many of the mails carried each confidence level. */
  byConfidence: Record<AdviceConfidence, number>;
  /** The reasons the model gave, deduplicated, so the card can say why. */
  reasons: string[];
  /** Advice ids, in the same order as `remoteIds` - the decision call needs them. */
  adviceIds: number[];
  /** A sender card's address; null for an action card. */
  sender?: string;
  /** Who the mail in this card came from, biggest first. */
  bySender: { address: string; count: number }[];
}

/** `{ address -> count }` for a set of mails, biggest first. */
export function senderBreakdown(
  remoteIds: string[],
  messages: Map<string, MessageHeader>,
): { address: string; count: number }[] {
  const counts = new Map<string, number>();
  for (const remoteId of remoteIds) {
    const address = messages.get(remoteId)?.fromAddress;
    if (!address) continue;
    counts.set(address, (counts.get(address) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([address, count]) => ({ address, count }))
    .sort((left, right) => right.count - left.count || left.address.localeCompare(right.address));
}

/** Suggestions that need the user personally; never batched. */
export interface PersonalItem {
  advice: AdviceRecord;
  subject: string | null;
  fromAddress: string;
  action: AdvisedAction;
}

export interface DecisionBoard {
  cards: DecisionGroup[];
  /** The cards beyond `VISIBLE_CARDS`, folded into one row by the UI. */
  overflow: { cards: number; mail: number };
  /** reply / wait / remind / unsubscribe / nothing - shown, never batched. */
  personal: PersonalItem[];
  /** Mails with no suggestion yet. The board says so instead of pretending. */
  unsuggested: number;
}

export interface BuildInput {
  advice: AdviceRecord[];
  /** The message each suggestion is about, by `remoteId`. Missing = not loaded. */
  messages: Map<string, MessageHeader>;
  /** Senders ranked by pending volume; only used for sender cards. */
  senders: SenderSummary[];
  unsuggested: number;
  /** Shown in `label`; kept as a parameter so the function stays pure. */
  labels: { archive: string; delete: string };
}

/**
 * Group the queue.
 *
 * Ordering rule: biggest group first, because the card that settles the most
 * mail is the one worth the first click. Ties break on the action (archive
 * before delete: the reversible one first) and then on the key, so the order is
 * deterministic and a test can assert it.
 */
export function buildDecisionBoard(input: BuildInput): DecisionBoard {
  const { advice, messages, senders, labels } = input;

  // Only pending suggestions are decisions to make. An accepted or dismissed
  // one already happened; showing it again would ask the same question twice.
  const pending = advice.filter((record) => record.decision === "pending");

  const personal: PersonalItem[] = [];
  const byKey = new Map<string, DecisionGroup>();

  for (const record of pending) {
    const action = record.advice.action;
    if (!EXECUTABLE.has(action)) {
      const message = messages.get(record.remoteId);
      personal.push({
        advice: record,
        subject: message?.subject ?? null,
        fromAddress: message?.fromAddress ?? "",
        action,
      });
      continue;
    }
    const executable = action as ExecutableAction;
    const key = `action:${executable}:${record.advice.category ?? "other"}`;
    let group = byKey.get(key);
    if (!group) {
      group = {
        id: key,
        kind: "action",
        action: executable,
        label: executable === "archive" ? labels.archive : labels.delete,
        remoteIds: [],
        samples: [],
        bySource: { heuristic: 0, ai: 0 },
        byConfidence: { high: 0, medium: 0, low: 0 },
        reasons: [],
        adviceIds: [],
        bySender: [],
      };
      byKey.set(key, group);
    }
    appendToGroup(group, record, messages);
  }

  // Sender cards: an address that writes a lot, for mail the action groups did
  // NOT already collect.
  //
  // Why "not already collected" is the rule, measured rather than assumed: on
  // the reference mailbox 322 judged mails collapse into exactly two action
  // groups (185 newsletter + 137 notification). Letting sender cards claim that
  // mail first produces seven-plus cards for the same 322 mails - more
  // decisions, not fewer, which is the opposite of the point. A sender card
  // therefore only earns its place when it collects mail that would otherwise
  // need several separate decisions.
  const alreadyGrouped = new Set<string>();
  for (const group of byKey.values()) {
    for (const remoteId of group.remoteIds) alreadyGrouped.add(remoteId);
  }
  for (const sender of senders) {
    if (sender.totalCount < SENDER_THRESHOLD) continue;
    const mine = pending.filter(
      (record) =>
        messages.get(record.remoteId)?.fromAddress === sender.address &&
        !alreadyGrouped.has(record.remoteId) &&
        EXECUTABLE.has(record.advice.action),
    );
    if (mine.length < SENDER_THRESHOLD) continue;
    const group: DecisionGroup = {
      id: `sender:${sender.address}`,
      kind: "sender",
      // A sender card archives by default: delete is the one action that needs a
      // per-mail look, and a bulk button labelled "delete" over an address is
      // the single most dangerous control this product could ship.
      action: "archive",
      label: labels.archive,
      remoteIds: [],
      samples: [],
      bySource: { heuristic: 0, ai: 0 },
      byConfidence: { high: 0, medium: 0, low: 0 },
      reasons: [],
      adviceIds: [],
      sender: sender.address,
      bySender: [],
    };
    for (const record of mine) appendToGroup(group, record, messages);
    byKey.set(group.id, group);
  }

  // Per-card sender breakdown, so a 185-mail card is not a black box: the user
  // can see whether one address owns all of it before pressing the button.
  for (const group of byKey.values()) {
    group.bySender = senderBreakdown(group.remoteIds, messages);
  }

  const cards = [...byKey.values()]
    .filter((group) => group.remoteIds.length > 0)
    .sort(compareGroups);

  const visible = cards.slice(0, VISIBLE_CARDS);
  const hidden = cards.slice(VISIBLE_CARDS);

  return {
    cards: visible,
    overflow: {
      cards: hidden.length,
      mail: hidden.reduce((sum, group) => sum + group.remoteIds.length, 0),
    },
    personal: personal.sort((left, right) =>
      (left.subject ?? "").localeCompare(right.subject ?? ""),
    ),
    unsuggested: input.unsuggested,
  };
}

function appendToGroup(
  group: DecisionGroup,
  record: AdviceRecord,
  messages: Map<string, MessageHeader>,
): void {
  group.remoteIds.push(record.remoteId);
  group.adviceIds.push(record.id);
  group.bySource[record.source === "ai" ? "ai" : "heuristic"] += 1;
  const confidence = record.advice.confidence;
  if (confidence === "high" || confidence === "medium" || confidence === "low") {
    group.byConfidence[confidence] += 1;
  }
  const rationale = record.advice.rationale?.trim();
  if (rationale && !group.reasons.includes(rationale)) group.reasons.push(rationale);
  if (group.samples.length < 3) {
    const message = messages.get(record.remoteId);
    group.samples.push({
      remoteId: record.remoteId,
      subject: message?.subject ?? null,
      fromAddress: message?.fromAddress ?? "",
    });
  }
}

function compareGroups(left: DecisionGroup, right: DecisionGroup): number {
  if (left.remoteIds.length !== right.remoteIds.length) {
    return right.remoteIds.length - left.remoteIds.length;
  }
  if (left.action !== right.action) return left.action === "archive" ? -1 : 1;
  return left.id.localeCompare(right.id);
}

/**
 * Split a card's mail into the part that succeeded and the part that did not,
 * after a bulk write.
 *
 * The decision call must only record the mails that really moved: recording the
 * whole card would tell the user "12 handled" when three are still in the inbox.
 * Returns the ids to record and the count that failed.
 */
export function partitionBulkOutcome(
  remoteIds: string[],
  adviceIds: number[],
  items: { remoteId: string; ok: boolean }[],
): { acceptedRemoteIds: string[]; acceptedAdviceIds: number[]; failed: number } {
  const succeeded = new Set(items.filter((item) => item.ok).map((item) => item.remoteId));
  const acceptedRemoteIds: string[] = [];
  const acceptedAdviceIds: number[] = [];
  for (let index = 0; index < remoteIds.length; index += 1) {
    if (!succeeded.has(remoteIds[index])) continue;
    acceptedRemoteIds.push(remoteIds[index]);
    const adviceId = adviceIds[index];
    if (adviceId !== undefined) acceptedAdviceIds.push(adviceId);
  }
  return {
    acceptedRemoteIds,
    acceptedAdviceIds,
    failed: remoteIds.length - acceptedRemoteIds.length,
  };
}

/**
 * The sentence the progress bar uses.
 *
 * The two layers are reported apart on purpose: the user is entitled to know
 * that most of this was a rule and only the remainder cost money. Merging them
 * into "322 done" would hide which half the model touched.
 */
export function triageSummary(bySource: { heuristic: number; ai: number }, unsuggested: number): string {
  return `规则已判 ${bySource.heuristic} · AI 已判 ${bySource.ai} · 未判 ${unsuggested}`;
}

/** Whether a run ended for a reason the user must act on. */
export function runNeedsAttention(state: string): boolean {
  return state === "stopped-budget" || state === "stopped-error";
}

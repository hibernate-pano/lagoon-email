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
  const executable: AdviceRecord[] = [];

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
    executable.push(record);
  }

  // The action group a record belongs to. A function because the sender pass
  // below has to ask the same question before any group exists.
  const keyOf = (record: AdviceRecord): string =>
    `action:${record.advice.action}:${record.advice.category ?? "other"}`;

  // Pass one: which records sit in which action group.
  const membersByKey = new Map<string, AdviceRecord[]>();
  for (const record of executable) {
    const key = keyOf(record);
    const bucket = membersByKey.get(key);
    if (bucket) bucket.push(record);
    else membersByKey.set(key, [record]);
  }

  // Sender cards: one address that writes a lot, as a single decision.
  //
  // The rule, measured rather than assumed. On the reference mailbox the
  // judged mail collapses into a handful of action groups, and the one
  // address that owns ten or more archivable mails (16 of them) has all 16
  // inside ONE group - archive:notification, which holds 34 mails from ten
  // addresses. A sender card that claimed those 16 would leave that group at
  // 18 mails and add a card of its own: eight decisions instead of seven.
  // More decisions, not fewer - the opposite of the point.
  //
  // So a sender card may only take mail when it genuinely replaces
  // decisions: the address's mail has to sit in MORE THAN ONE action group
  // (otherwise the action group is already the compact way to say it), and
  // taking it has to empty at least one of those groups (otherwise the card
  // is added next to the groups it duplicates).
  //
  // Only "archive" mail is ever claimed. A sender card archives by default,
  // and a bulk button labelled "delete" over an address is the single most
  // dangerous control this product could ship - a delete suggestion needs a
  // per-mail look and stays in its own group.
  const claimed = new Set<number>();
  const senderClaims: { sender: SenderSummary; records: AdviceRecord[] }[] = [];

  for (const sender of senders) {
    if (sender.totalCount < SENDER_THRESHOLD) continue;
    const mine = executable.filter(
      (record) =>
        messages.get(record.remoteId)?.fromAddress === sender.address &&
        record.advice.action === "archive" &&
        !claimed.has(record.id),
    );
    if (mine.length < SENDER_THRESHOLD) continue;

    // Which action groups would this address's mail come out of?
    const keys = [...new Set(mine.map(keyOf))];
    if (keys.length < 2) continue;

    // Does taking it empty a group? A group is emptied when every mail in it
    // belongs to this address - that group is no longer a decision, and the
    // sender card replaces it.
    const mineIds = new Set(mine.map((record) => record.id));
    const empties = keys.filter((key) => {
      const members = membersByKey.get(key);
      if (!members || members.length === 0) return false;
      return members.every((member) => mineIds.has(member.id));
    });
    if (empties.length < 1) continue;

    for (const record of mine) claimed.add(record.id);
    senderClaims.push({ sender, records: mine });
    for (const key of empties) membersByKey.delete(key);
  }

  // Pass two: build the cards. The groups are built from the records that
  // were not claimed, so every counter (bySource, byConfidence, reasons) is
  // counted from the mail the card actually acts on - and no mail sits on two
  // cards, which would make one click act on it twice.
  const byKey = new Map<string, DecisionGroup>();

  for (const [key, members] of membersByKey) {
    const unclaimed = members.filter((record) => !claimed.has(record.id));
    if (unclaimed.length === 0) continue;
    const first = unclaimed[0];
    const action = first.advice.action as ExecutableAction;
    const group: DecisionGroup = {
      id: key,
      kind: "action",
      action,
      label: action === "archive" ? labels.archive : labels.delete,
      remoteIds: [],
      samples: [],
      bySource: { heuristic: 0, ai: 0 },
      byConfidence: { high: 0, medium: 0, low: 0 },
      reasons: [],
      adviceIds: [],
      bySender: [],
    };
    for (const record of unclaimed) appendToGroup(group, record, messages);
    byKey.set(key, group);
  }

  for (const { sender, records: mine } of senderClaims) {
    const group: DecisionGroup = {
      id: `sender:${sender.address}`,
      kind: "sender",
      // A sender card archives by default: delete is the one action that needs
      // a per-mail look, and a bulk button labelled "delete" over an address is
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

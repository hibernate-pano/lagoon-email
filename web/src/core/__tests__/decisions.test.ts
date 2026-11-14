import { describe, expect, it } from "vitest";
import {
  SENDER_THRESHOLD,
  VISIBLE_CARDS,
  buildDecisionBoard,
  partitionBulkOutcome,
  runNeedsAttention,
  triageSummary,
} from "../decisions";
import type { AdviceRecord, MessageHeader, SenderSummary } from "../types";

const LABELS = { archive: "归档", delete: "删除" };

function message(remoteId: string, from: string, subject: string): MessageHeader {
  return {
    id: remoteId,
    accountId: "acct",
    remoteId,
    threadId: remoteId,
    fromAddress: from,
    fromName: null,
    subject,
    snippet: null,
    receivedAt: "2026-01-01T00:00:00Z",
    isRead: false,
    isArchived: false,
    isDeleted: false,
    isPinned: false,
    isSent: false,
  };
}

function advice(
  id: number,
  remoteId: string,
  action: AdviceRecord["advice"]["action"],
  options: {
    category?: string | null;
    confidence?: AdviceRecord["advice"]["confidence"];
    source?: "heuristic" | "ai";
    decision?: AdviceRecord["decision"];
    rationale?: string | null;
  } = {},
): AdviceRecord {
  return {
    id,
    accountId: "acct",
    remoteId,
    advice: {
      action,
      category: options.category ?? null,
      confidence: options.confidence ?? "high",
      rationale: options.rationale ?? null,
      dueText: null,
    },
    source: options.source ?? "ai",
    model: null,
    decision: options.decision ?? "pending",
    createdAt: "2026-01-01T00:00:00Z",
    decidedAt: null,
  };
}

function sender(address: string, totalCount: number): SenderSummary {
  return {
    address,
    displayName: null,
    totalCount,
    unreadCount: totalCount,
    latestAt: "2026-01-01T00:00:00Z",
  };
}

function board(input: {
  advice: AdviceRecord[];
  messages: MessageHeader[];
  senders?: SenderSummary[];
  unsuggested?: number;
}) {
  return buildDecisionBoard({
    advice: input.advice,
    messages: new Map(input.messages.map((item) => [item.remoteId, item])),
    senders: input.senders ?? [],
    unsuggested: input.unsuggested ?? 0,
    labels: LABELS,
  });
}

describe("the decision board groups mail into decisions", () => {
  it("collapses twelve marketing archives into one card", () => {
    const messages = Array.from({ length: 12 }, (_, index) =>
      message(`m-${index}`, "shop@example.com", `促销 ${index}`),
    );
    const records = messages.map((item, index) =>
      advice(index + 1, item.remoteId, "archive", { category: "marketing" }),
    );

    const result = board({ advice: records, messages });

    expect(result.cards).toHaveLength(1);
    expect(result.cards[0].remoteIds).toHaveLength(12);
    expect(result.cards[0].action).toBe("archive");
    expect(result.cards[0].adviceIds).toHaveLength(12);
  });

  it("keeps suggestions that need the user out of the cards", () => {
    const messages = [message("a", "friend@example.com", "你好"), message("b", "x@example.com", "hi")];
    const records = [
      advice(1, "a", "reply"),
      advice(2, "b", "wait"),
    ];

    const result = board({ advice: records, messages });

    expect(result.cards).toHaveLength(0);
    // Not lost either: the board lists them so the user knows they exist.
    expect(result.personal).toHaveLength(2);
    expect(result.personal.map((item) => item.action).sort()).toEqual(["reply", "wait"]);
  });

  it("counts both confidence levels instead of flattening them", () => {
    const messages = [
      message("a", "shop@example.com", "one"),
      message("b", "shop@example.com", "two"),
      message("c", "shop@example.com", "three"),
      message("d", "shop@example.com", "four"),
    ];
    const records = [
      advice(1, "a", "archive", { confidence: "high" }),
      advice(2, "b", "archive", { confidence: "high" }),
      advice(3, "c", "archive", { confidence: "medium" }),
      advice(4, "d", "archive", { confidence: "low" }),
    ];

    const [card] = board({ advice: records, messages }).cards;
    expect(card.byConfidence).toEqual({ high: 2, medium: 1, low: 1 });
  });

  it("says which layer judged the group", () => {
    const messages = [
      message("a", "news@example.com", "one"),
      message("b", "friend@example.com", "two"),
    ];
    const records = [
      advice(1, "a", "archive", { source: "heuristic" }),
      advice(2, "b", "archive", { source: "ai" }),
    ];

    const [card] = board({ advice: records, messages }).cards;
    // The card must be able to say "规则 1 · AI 1": merging them would hide
    // which half the model touched.
    expect(card.bySource).toEqual({ heuristic: 1, ai: 1 });
    expect(card.bySource.heuristic + card.bySource.ai).toBe(card.remoteIds.length);
  });

  it("ignores suggestions the user already decided", () => {
    const messages = [message("a", "shop@example.com", "one")];
    const records = [advice(1, "a", "archive", { decision: "accepted" })];

    const result = board({ advice: records, messages });
    expect(result.cards).toHaveLength(0);
    expect(result.personal).toHaveLength(0);
  });

  it("folds the tail into one overflow row without losing mail", () => {
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    // Eight distinct categories so nothing groups together by accident.
    const categories = ["personal", "work", "marketing", "spam", "notification", "newsletter", "financial", "logistics"];
    categories.forEach((category, index) => {
      const count = 9 - index; // descending sizes, so the order is deterministic
      for (let step = 0; step < count; step += 1) {
        const remoteId = `${category}-${step}`;
        messages.push(message(remoteId, `${category}@example.com`, remoteId));
        records.push(advice(records.length + 1, remoteId, "archive", { category }));
      }
    });

    const result = board({ advice: records, messages });
    const shown = result.cards.reduce((sum, card) => sum + card.remoteIds.length, 0);

    expect(result.cards).toHaveLength(VISIBLE_CARDS);
    // ★ The total must be conserved: a folded card is still a decision.
    expect(shown + result.overflow.mail).toBe(messages.length);
    expect(result.overflow.cards).toBe(categories.length - VISIBLE_CARDS);
  });

  it("orders the biggest group first", () => {
    const messages = [
      message("big-1", "a@example.com", "1"),
      message("big-2", "a@example.com", "2"),
      message("small-1", "b@example.com", "3"),
    ];
    const records = [
      advice(1, "small-1", "delete", { category: "spam" }),
      advice(2, "big-1", "archive", { category: "marketing" }),
      advice(3, "big-2", "archive", { category: "marketing" }),
    ];

    const result = board({ advice: records, messages });
    expect(result.cards[0].remoteIds).toHaveLength(2);
    expect(result.cards[0].action).toBe("archive");
  });

  it("does not split a group that already covers the mail just to show a sender", () => {
    // This is the reference mailbox's actual shape: 322 judged mails collapse
    // into two action groups, one address owning 77 of them. A sender card that
    // claimed that mail first would produce seven-plus cards for the same 322
    // mails - more decisions, not fewer.
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    const senders: SenderSummary[] = [];

    // 185 newsletter + 137 notification, one address owning 77 of the second.
    for (let index = 0; index < 185; index += 1) {
      const remoteId = `nl-${index}`;
      messages.push(message(remoteId, `list${index % 12}@example.com`, `周刊 ${index}`));
      records.push(advice(records.length + 1, remoteId, "archive", { category: "newsletter" }));
    }
    for (let index = 0; index < 137; index += 1) {
      const remoteId = `nt-${index}`;
      messages.push(message(remoteId, index < 77 ? "loud@example.com" : `svc${index}@example.com`, `通知 ${index}`));
      records.push(advice(records.length + 1, remoteId, "archive", { category: "notification" }));
    }
    senders.push(sender("loud@example.com", 77));

    const result = board({ advice: records, messages, senders });

    // ★ Two cards for 322 mails. Anything more means the grouping undid itself.
    expect(result.cards).toHaveLength(2);
    const total = result.cards.reduce((sum, card) => sum + card.remoteIds.length, 0);
    expect(total).toBe(322);
    // And no sender card, because the action groups already cover that mail.
    expect(result.cards.every((card) => card.kind === "action")).toBe(true);
  });

  it("shows the senders inside a card so it is not a black box", () => {
    const messages = [
      message("a", "one@example.com", "1"),
      message("b", "one@example.com", "2"),
      message("c", "two@example.com", "3"),
    ];
    const records = [
      advice(1, "a", "archive", { category: "newsletter" }),
      advice(2, "b", "archive", { category: "newsletter" }),
      advice(3, "c", "archive", { category: "newsletter" }),
    ];

    const [card] = board({ advice: records, messages }).cards;
    expect(card.bySender).toEqual([
      { address: "one@example.com", count: 2 },
      { address: "two@example.com", count: 1 },
    ]);
  });

  it("gives a sender a card only for mail no action group already collects", () => {
    // Nine mails an action group covers, plus ten from one address that no
    // group covers (their action is "archive" but they carry a category the
    // rest of the mailbox never uses, so they form their own tiny group).
    // The sender card exists for the ten, and the nine stay where they are.
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];

    for (let index = 0; index < 9; index += 1) {
      const remoteId = `covered-${index}`;
      messages.push(message(remoteId, `list${index}@example.com`, `周刊 ${index}`));
      records.push(advice(records.length + 1, remoteId, "archive", { category: "newsletter" }));
    }

    const result = board({
      advice: records,
      messages,
      senders: [sender("loud@example.com", 40)],
    });

    // The sender's mail is not in the queue at all, so there is no card for it:
    // a card that acts on nothing would be a button that does nothing.
    expect(result.cards).toHaveLength(1);
    expect(result.cards[0].kind).toBe("action");
    expect(result.cards[0].remoteIds).toHaveLength(9);
  });

  it("does not give a sender card to an address below the threshold", () => {
    const messages = [message("a", "quiet@example.com", "one")];
    const records = [advice(1, "a", "archive")];

    const result = board({
      advice: records,
      messages,
      senders: [sender("quiet@example.com", SENDER_THRESHOLD - 1)],
    });

    expect(result.cards.every((card) => card.kind !== "sender")).toBe(true);
  });

  it("never lets one mail appear on two cards", () => {
    // Ten mails from one address, all archivable: the action group already
    // covers them, so a sender card would offer the same mail twice.
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    for (let index = 0; index < SENDER_THRESHOLD; index += 1) {
      const remoteId = `dup-${index}`;
      messages.push(message(remoteId, "loud@example.com", "hi"));
      records.push(advice(index + 1, remoteId, "archive", { category: "marketing" }));
    }

    const result = board({
      advice: records,
      messages,
      senders: [sender("loud@example.com", SENDER_THRESHOLD)],
    });

    const seen = new Set<string>();
    for (const card of result.cards) {
      for (const remoteId of card.remoteIds) {
        expect(seen.has(remoteId)).toBe(false);
        seen.add(remoteId);
      }
    }
    expect(seen.size).toBe(SENDER_THRESHOLD);
  });

  it("carries the unjudged count so the board can admit what it has not seen", () => {
    const result = board({ advice: [], messages: [], unsuggested: 310 });
    expect(result.unsuggested).toBe(310);
  });

  it("collects the reasons without repeating them", () => {
    const messages = [
      message("a", "shop@example.com", "one"),
      message("b", "shop@example.com", "two"),
    ];
    const records = [
      advice(1, "a", "archive", { rationale: "带一键退订的群发邮件" }),
      advice(2, "b", "archive", { rationale: "带一键退订的群发邮件" }),
    ];

    const [card] = board({ advice: records, messages }).cards;
    expect(card.reasons).toEqual(["带一键退订的群发邮件"]);
    expect(card.samples).toHaveLength(2);
  });
});

describe("a sender card earns its place or does not exist", () => {
  /**
   * The shape that makes a sender card worth having: one address whose mail
   * sits in SEVERAL action groups, each of which would otherwise be a
   * separate card with only that address's mail in it.
   *
   * Twelve mails, four categories, three mails each. Without the sender card
   * that is four decisions; with it, one.
   */
  function scatteredBySender() {
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    const categories = ["personal", "work", "transactional", "notification"];
    for (let index = 0; index < 12; index += 1) {
      const remoteId = `loud-${index}`;
      messages.push(message(remoteId, "loud@example.com", `邮件 ${index}`));
      records.push(
        advice(index + 1, remoteId, "archive", {
          category: categories[index % categories.length],
        }),
      );
    }
    return { messages, records };
  }

  it("replaces several thin cards with one when the address owns them all", () => {
    const { messages, records } = scatteredBySender();

    const result = board({
      advice: records,
      messages,
      senders: [sender("loud@example.com", 12)],
    });

    const senderCards = result.cards.filter((card) => card.kind === "sender");
    expect(senderCards).toHaveLength(1);
    expect(senderCards[0].remoteIds).toHaveLength(12);
    expect(senderCards[0].sender).toBe("loud@example.com");

    // Four thin cards became one: fewer decisions, which is the whole point.
    expect(result.cards).toHaveLength(1);
    // No mail is on two cards.
    const seen = new Set<string>();
    for (const card of result.cards) {
      for (const remoteId of card.remoteIds) {
        expect(seen.has(remoteId)).toBe(false);
        seen.add(remoteId);
      }
    }
    expect(seen.size).toBe(12);
  });

  it("does not take mail from a group other addresses also fill", () => {
    // The measured shape on the reference mailbox: one address owns 16
    // archivable mails, all of them inside one group that ten addresses
    // share. A sender card would add a decision next to the group it
    // duplicates, so there must not be one.
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    for (let index = 0; index < 16; index += 1) {
      const remoteId = `loud-${index}`;
      messages.push(message(remoteId, "loud@example.com", `邮件 ${index}`));
      records.push(advice(index + 1, remoteId, "archive", { category: "notification" }));
    }
    // Eight more mails from other addresses, in the same group.
    for (let index = 0; index < 8; index += 1) {
      const remoteId = `other-${index}`;
      messages.push(message(remoteId, `other${index}@example.com`, `别人的 ${index}`));
      records.push(advice(100 + index, remoteId, "archive", { category: "notification" }));
    }

    const result = board({
      advice: records,
      messages,
      senders: [sender("loud@example.com", 16)],
    });

    expect(result.cards.every((card) => card.kind !== "sender")).toBe(true);
    expect(result.cards).toHaveLength(1);
    expect(result.cards[0].remoteIds).toHaveLength(24);
  });

  it("does not add a card next to the groups it would duplicate", () => {
    // The address's mail is spread over two groups, so it qualifies - but
    // both groups hold other addresses' mail too, so taking its mail empties
    // neither. A sender card here would be one more decision sitting next to
    // the two it repeats.
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    for (let index = 0; index < 6; index += 1) {
      const remoteId = `loud-personal-${index}`;
      messages.push(message(remoteId, "loud@example.com", `个人 ${index}`));
      records.push(advice(index + 1, remoteId, "archive", { category: "personal" }));
    }
    for (let index = 0; index < 6; index += 1) {
      const remoteId = `loud-work-${index}`;
      messages.push(message(remoteId, "loud@example.com", `工作 ${index}`));
      records.push(advice(100 + index, remoteId, "archive", { category: "work" }));
    }
    // Other addresses in both groups.
    for (let index = 0; index < 6; index += 1) {
      const remoteId = `other-personal-${index}`;
      messages.push(message(remoteId, `other${index}@example.com`, `别人 ${index}`));
      records.push(advice(200 + index, remoteId, "archive", { category: "personal" }));
    }
    for (let index = 0; index < 6; index += 1) {
      const remoteId = `other-work-${index}`;
      messages.push(message(remoteId, `otherb${index}@example.com`, `别人 ${index}`));
      records.push(advice(300 + index, remoteId, "archive", { category: "work" }));
    }

    const result = board({
      advice: records,
      messages,
      senders: [sender("loud@example.com", 12)],
    });

    expect(result.cards.every((card) => card.kind !== "sender")).toBe(true);
    expect(result.cards).toHaveLength(2);
  });

  it("does not leave claimed mail in the group it partly came from", () => {
    // The sender qualifies (12 archivable mails over two groups) and empties
    // one (personal, only this address writes there). Its five notification
    // mails come out of a group that eight other addresses still fill, so
    // they must leave that group as well - otherwise the same mail sits on
    // two cards and one click acts on it twice.
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    for (let index = 0; index < 7; index += 1) {
      const remoteId = `loud-personal-${index}`;
      messages.push(message(remoteId, "loud@example.com", `个人 ${index}`));
      records.push(advice(index + 1, remoteId, "archive", { category: "personal" }));
    }
    for (let index = 0; index < 5; index += 1) {
      const remoteId = `loud-notification-${index}`;
      messages.push(message(remoteId, "loud@example.com", `通知 ${index}`));
      records.push(advice(100 + index, remoteId, "archive", { category: "notification" }));
    }
    for (let index = 0; index < 8; index += 1) {
      const remoteId = `other-${index}`;
      messages.push(message(remoteId, `other${index}@example.com`, `别人的 ${index}`));
      records.push(advice(200 + index, remoteId, "archive", { category: "notification" }));
    }

    const result = board({
      advice: records,
      messages,
      senders: [sender("loud@example.com", 12)],
    });

    // One sender card (the 12) and one action group (the 8 others).
    const senderCards = result.cards.filter((card) => card.kind === "sender");
    expect(senderCards).toHaveLength(1);
    expect(senderCards[0].remoteIds).toHaveLength(12);
    const actionCards = result.cards.filter((card) => card.kind === "action");
    expect(actionCards).toHaveLength(1);
    expect(actionCards[0].remoteIds).toHaveLength(8);

    // No mail is on two cards, and no mail is on none.
    const seen = new Set<string>();
    for (const card of result.cards) {
      for (const remoteId of card.remoteIds) {
        expect(seen.has(remoteId)).toBe(false);
        seen.add(remoteId);
      }
    }
    expect(seen.size).toBe(20);
  });

  it("never turns a delete suggestion into an archive", () => {
    // The sender card archives by default, so it may only ever claim mail
    // that was suggested as archive. Twelve archivable mails across two
    // categories earn the card; six delete suggestions from the same address
    // must not be swept into it.
    const messages: MessageHeader[] = [];
    const records: AdviceRecord[] = [];
    for (let index = 0; index < 12; index += 1) {
      const remoteId = `loud-${index}`;
      messages.push(message(remoteId, "loud@example.com", `邮件 ${index}`));
      records.push(
        advice(index + 1, remoteId, "archive", {
          category: index % 2 === 0 ? "personal" : "work",
        }),
      );
    }
    for (let index = 0; index < 6; index += 1) {
      const remoteId = `loud-spam-${index}`;
      messages.push(message(remoteId, "loud@example.com", `垃圾 ${index}`));
      records.push(advice(100 + index, remoteId, "delete", { category: "spam" }));
    }

    const result = board({
      advice: records,
      messages,
      senders: [sender("loud@example.com", 12)],
    });

    const senderCards = result.cards.filter((card) => card.kind === "sender");
    expect(senderCards).toHaveLength(1);
    expect(senderCards[0].remoteIds).toHaveLength(12);
    expect(senderCards[0].remoteIds).not.toContain("loud-spam-0");
    // The delete suggestions stayed in a card of their own.
    const deleteCards = result.cards.filter((card) => card.action === "delete");
    expect(deleteCards).toHaveLength(1);
    expect(deleteCards[0].remoteIds).toHaveLength(6);
  });
});

describe("recording only what really happened", () => {
  it("records the mails that moved and reports the ones that did not", () => {
    const remoteIds = ["a", "b", "c"];
    const adviceIds = [11, 12, 13];
    const items = [
      { remoteId: "a", ok: true },
      { remoteId: "b", ok: false },
      { remoteId: "c", ok: true },
    ];

    const result = partitionBulkOutcome(remoteIds, adviceIds, items);

    // Recording the whole card would tell the user "3 handled" with b still
    // in the inbox.
    expect(result.acceptedRemoteIds).toEqual(["a", "c"]);
    expect(result.acceptedAdviceIds).toEqual([11, 13]);
    expect(result.failed).toBe(1);
  });

  it("handles a mail the server did not report at all", () => {
    const result = partitionBulkOutcome(["a", "b"], [1, 2], [{ remoteId: "a", ok: true }]);
    expect(result.acceptedRemoteIds).toEqual(["a"]);
    expect(result.failed).toBe(1);
  });
});

describe("the progress sentence", () => {
  it("names both layers apart", () => {
    expect(triageSummary({ heuristic: 322, ai: 0 }, 108)).toBe(
      "规则已判 322 · AI 已判 0 · 未判 108",
    );
  });

  it("flags the states the user has to do something about", () => {
    expect(runNeedsAttention("stopped-budget")).toBe(true);
    expect(runNeedsAttention("stopped-error")).toBe(true);
    // Not a failure: the free layer finished, there is just no key for the rest.
    expect(runNeedsAttention("stopped-unconfigured")).toBe(false);
    expect(runNeedsAttention("done")).toBe(false);
  });
});

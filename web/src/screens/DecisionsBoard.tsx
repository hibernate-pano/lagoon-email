/**
 * The decision board: the first screen, because the first screen is where the
 * product either compresses the mailbox or does not.
 *
 * What makes this screen unlike the briefing feed: the briefing is the inbox
 * grouped, so it still asks the user to read 430 rows. This asks them to settle
 * a handful of things. A card names the mail it would act on, says who judged it
 * (a rule or the model) and repeats the reason. None of that is decoration:
 * without the sample the button is a black box, and a black box gets pressed
 * once and then never again.
 *
 * Ordering of the work, which is not negotiable:
 *   1. the mails actually move (bulk archive / delete, already undo-tested);
 *   2. only then is the decision recorded, and only for the mails that moved.
 * A failed write leaves the suggestion pending, so the queue keeps telling the
 * truth instead of claiming twelve mails were handled when three were not.
 */
import { useMemo, useState, type ReactNode } from "react";
import type {
  AdviceRecord,
  MessageHeader,
  SenderSummary,
  TriageStatus,
} from "../core/types";
import type { Outcome } from "../core/async";
import {
  buildDecisionBoard,
  partitionBulkOutcome,
  runNeedsAttention,
  triageSummary,
  type DecisionGroup,
} from "../core/decisions";
import type { WriteBridge } from "../core/uiBridge";
import {
  bulkAction,
  recordDecisions,
  undoBulk,
  type WriteFailure,
} from "../core/writes";
import { AsyncSurface } from "../ui/AsyncSurface";
import { t } from "../l10n/zh";

export interface DecisionsBoardProps {
  /** Every suggestion for the account (pending and decided; the board filters). */
  advice: { outcome: Outcome<{ advice: AdviceRecord[] }>; refresh: () => void };
  /** The rows the suggestions point at. Missing entries mean "not loaded". */
  messages: Map<string, MessageHeader>;
  /** Sender ranking, for the "this address writes a lot" cards. */
  senders: SenderSummary[];
  /** How many mails nobody judged yet. Shown, never rounded to zero. */
  unsuggested: number;
  /** The triage batch's state, or null when it was never asked about. */
  onStartTriage: () => void;
  onCancelTriage: () => void;
  /**
   * The batch's state. `null` means "not asked yet", which the bar renders as
   * a plain invitation rather than as a zero.
   */
  triage?: TriageStatus | null;
  writes: WriteBridge;
  onOpenMessage: (remoteId: string) => void;
  onSettled: () => void;
  /** Confirmation for a destructive batch; the caller owns the dialog. */
  onConfirmDelete: (count: number, run: () => void) => void;
  onError: (failure: WriteFailure) => void;
  onToast: (text: string) => void;
}

export function DecisionsBoard(props: DecisionsBoardProps): ReactNode {
  const { advice, messages, senders, writes } = props;
  const [expanded, setExpanded] = useState<Set<string>>(() => new Set());
  const [busyCard, setBusyCard] = useState<string | null>(null);
  const [lastBatch, setLastBatch] = useState<{ actionIds: number[]; count: number } | null>(null);

  const board = useMemo(() => {
    const rows = advice.outcome.phase === "ready" || advice.outcome.phase === "empty"
      ? advice.outcome.data.advice
      : [];
    return buildDecisionBoard({
      advice: rows,
      messages,
      senders,
      unsuggested: props.unsuggested,
      labels: { archive: t.decisions.actionArchive, delete: t.decisions.actionDelete },
    });
  }, [advice.outcome, messages, senders, props.unsuggested]);

  const runCard = async (card: DecisionGroup) => {
    const accountId = adviceAccount(advice);
    if (!accountId) return;
    const execute = async () => {
      setBusyCard(card.id);
      try {
        const result = await bulkAction(card.action, card.remoteIds, accountId);
        if (!result.ok) {
          props.onError(result);
          return;
        }
        // ★ Only the mails that really moved are recorded. The rest stay
        // pending, and the card will still be here next time.
        const split = partitionBulkOutcome(card.remoteIds, card.adviceIds, result.items);
        if (split.acceptedAdviceIds.length > 0) {
          await recordDecisions(split.acceptedAdviceIds, accountId, "accepted");
        }
        const actionIds = result.items
          .filter((item) => item.ok && typeof item.actionId === "number")
          .map((item) => item.actionId as number);
        if (actionIds.length > 0) {
          setLastBatch({ actionIds, count: split.acceptedRemoteIds.length });
        }
        if (split.failed > 0) {
          props.onToast(t.decisions.partial(split.failed));
        } else {
          props.onToast(
            card.action === "archive"
              ? t.m2.toast.archived(split.acceptedRemoteIds.length)
              : t.m2.toast.deleted(split.acceptedRemoteIds.length),
          );
        }
        props.onSettled();
      } finally {
        setBusyCard(null);
      }
    };
    if (card.action === "delete") {
      // A bulk delete is the one verb that has to ask first, and its sentence
      // has to name the count and the way back.
      props.onConfirmDelete(card.remoteIds.length, () => void execute());
      return;
    }
    await execute();
  };

  const undoLast = async () => {
    const accountId = adviceAccount(advice);
    if (!lastBatch || !accountId) return;
    const result = await undoBulk(lastBatch.actionIds, accountId);
    if (!result.ok) {
      props.onError(result);
      return;
    }
    setLastBatch(null);
    props.onToast(t.m2.actions.undo);
    props.onSettled();
  };

  const content = () => {
    if (advice.outcome.phase === "loading") {
      return <p className="muted">{t.decisions.loading}</p>;
    }
    if (advice.outcome.phase === "unavailable" || advice.outcome.phase === "error") {
      // A failed read is not an empty queue: say "unknown", offer the retry.
      return (
        <AsyncSurface
          outcome={advice.outcome}
          onRetry={advice.refresh}
          empty={{ title: t.decisions.emptyNoAdvice }}
        >
          {() => null}
        </AsyncSurface>
      );
    }
    const empty = board.cards.length === 0 && board.personal.length === 0;
    if (empty) {
      // Three different facts, three different sentences: never one "nothing".
      const noAccount = advice.outcome.phase === "empty" && props.unsuggested === 0 && messages.size === 0;
      return (
        <div className="decisions-empty">
          <h2>{noAccount ? t.decisions.emptyNoAccount : t.decisions.emptyAllDone}</h2>
          <p className="muted">
            {noAccount ? t.decisions.unsuggestedHint : t.decisions.emptyAllDoneHint}
          </p>
        </div>
      );
    }
    return (
      <>
        {board.cards.map((card) => (
          <Card
            key={card.id}
            card={card}
            expanded={expanded.has(card.id)}
            busy={busyCard === card.id || writes.busy}
            onToggle={() =>
              setExpanded((current) => {
                const next = new Set(current);
                if (next.has(card.id)) next.delete(card.id);
                else next.add(card.id);
                return next;
              })
            }
            onRun={() => void runCard(card)}
            onOpen={props.onOpenMessage}
          />
        ))}
        {board.overflow.cards > 0 ? (
          <p className="decisions-overflow">
            {t.decisions.overflow(board.overflow.cards, board.overflow.mail)}
          </p>
        ) : null}
        {board.personal.length > 0 ? (
          <section className="decisions-personal">
            <h3>{t.decisions.personalTitle(board.personal.length)}</h3>
            <p className="muted">{t.decisions.personalHint}</p>
            <ul>
              {board.personal.map((item) => (
                <li key={item.advice.id}>
                  <button type="button" className="link" onClick={() => props.onOpenMessage(item.advice.remoteId)}>
                    {item.subject ?? item.advice.remoteId}
                  </button>
                  <span className="chip">{t.briefing.advice.actions[item.action] ?? item.action}</span>
                  {item.advice.advice.rationale ? (
                    <span className="rationale">{item.advice.advice.rationale}</span>
                  ) : null}
                </li>
              ))}
            </ul>
          </section>
        ) : null}
      </>
    );
  };

  return (
    <div className="decisions">
      <header className="decisions-head">
        <div>
          <h1>{t.decisions.title}</h1>
          <p className="muted">{t.decisions.subtitle}</p>
        </div>
        {lastBatch ? (
          <button type="button" className="btn" onClick={() => void undoLast()}>
            {t.m2.actions.undo} ({lastBatch.count})
          </button>
        ) : null}
      </header>

      <TriageBar
        triage={props.triage}
        unsuggested={props.unsuggested}
        onStart={props.onStartTriage}
        onCancel={props.onCancelTriage}
      />

      {content()}
    </div>
  );
}

/**
 * The progress line.
 *
 * It names both layers apart and it never hides the remainder: "还有 108 封没被
 * AI 看过" is the sentence this project exists to be able to say.
 */
function TriageBar(props: {
  triage?: DecisionsBoardProps["triage"];
  unsuggested: number;
  onStart: () => void;
  onCancel: () => void;
}): ReactNode {
  const { triage, unsuggested } = props;
  const run = triage?.run ?? null;
  if (!triage) {
    return (
      <div className="triage-bar">
        <span>{unsuggested > 0 ? t.decisions.unsuggested(unsuggested) : t.decisions.emptyAllDone}</span>
        <button type="button" className="btn" onClick={props.onStart} disabled={unsuggested === 0}>
          {t.decisions.startTriage}
        </button>
      </div>
    );
  }
  const summary = triageSummary(triage.bySource, unsuggested);
  if (triage.running) {
    return (
      <div className="triage-bar running">
        <span>
          {run?.phase === "ai" ? t.decisions.phaseAi : t.decisions.phaseHeuristic}
          {run && run.target > 0 ? ` ${run.done}/${run.target}` : ""}
        </span>
        <span className="muted">{summary}</span>
        <button type="button" className="btn" onClick={props.onCancel}>
          {t.decisions.cancelTriage}
        </button>
      </div>
    );
  }
  const state = run?.state ?? "";
  const needsAttention = runNeedsAttention(state);
  return (
    <div className={"triage-bar" + (needsAttention ? " warn" : "")}>
      <span>{summary}</span>
      {!triage.configured ? <span className="muted">{t.decisions.unconfigured}</span> : null}
      {state === "stopped-budget" ? <span className="chip warn">{t.decisions.budgetReached}</span> : null}
      {state === "stopped-error" && run?.lastError ? (
        <span className="chip err">{t.decisions.stoppedError(run.lastError)}</span>
      ) : null}
      {unsuggested > 0 ? (
        <button type="button" className="btn" onClick={props.onStart}>
          {t.decisions.startTriage}
        </button>
      ) : null}
    </div>
  );
}

function Card(props: {
  card: DecisionGroup;
  expanded: boolean;
  busy: boolean;
  onToggle: () => void;
  onRun: () => void;
  onOpen: (remoteId: string) => void;
}): ReactNode {
  const { card } = props;
  const confidence = t.decisions.cardConfidence(
    card.byConfidence.high,
    card.byConfidence.medium,
    card.byConfidence.low,
  );
  const source = t.decisions.cardSource(card.bySource.heuristic, card.bySource.ai);
  const samples = props.expanded ? card.samples : card.samples.slice(0, 3);
  return (
    <section className={"decision-card" + (card.action === "delete" ? " destructive" : "")}>
      <header>
        <strong>{card.label}</strong>
        {card.kind === "sender" ? <span className="chip">{t.decisions.senderCardTitle}</span> : null}
        <span className="count">{t.decisions.cardMailCount(card.remoteIds.length)}</span>
        {confidence ? <span className="chip">{confidence}</span> : null}
        {/* Who judged it: a rule this build ships, or a model that read it. */}
        {source ? <span className="chip src">{source}</span> : null}
      </header>

      {card.kind === "sender" && card.sender ? <p className="sender">{card.sender}</p> : null}

      {/* Who owns this card. A 185-mail card with no breakdown is a black box,
          and a black box earns one click and then distrust. */}
      {card.kind === "action" && card.bySender.length > 1 ? (
        <p className="decision-senders muted">
          {t.decisions.topSenders}：
          {card.bySender
            .slice(0, 3)
            .map((entry) => `${entry.address} ${entry.count}`)
            .join(" · ")}
          {card.bySender.length > 3
            ? ` · ${t.decisions.moreSenders(card.bySender.length - 3)}`
            : ""}
        </p>
      ) : null}

      <ul className="decision-samples">
        {samples.map((sample) => (
          <li key={sample.remoteId}>
            <button type="button" className="link" onClick={() => props.onOpen(sample.remoteId)}>
              {sample.subject ?? sample.remoteId}
            </button>
            <span className="muted"> · {sample.fromAddress}</span>
          </li>
        ))}
      </ul>
      {card.remoteIds.length > card.samples.length ? (
        <button type="button" className="link small" onClick={props.onToggle}>
          {props.expanded
            ? t.decisions.cardHideAll
            : t.decisions.cardShowAll(card.remoteIds.length)}
        </button>
      ) : null}

      {card.reasons.length > 0 ? (
        <p className="decision-why">
          <span className="muted">{t.decisions.cardWhy}</span>
          {card.reasons.slice(0, 2).join("；")}
        </p>
      ) : null}

      <footer>
        <button type="button" className="btn primary" onClick={props.onRun} disabled={props.busy}>
          {props.busy ? t.decisions.busy : `${card.label} · ${card.remoteIds.length}`}
        </button>
      </footer>
    </section>
  );
}

/** The account the suggestions belong to; the write calls need it. */
function adviceAccount(advice: { outcome: Outcome<{ advice: AdviceRecord[] }> }): string | null {
  if (advice.outcome.phase !== "ready" && advice.outcome.phase !== "empty") return null;
  const first = advice.outcome.data.advice[0];
  return first?.accountId ?? null;
}

/**
 * The AI suggestion inside a briefing row.
 *
 * This used to be read-only with the two verbs disabled and the tooltip "M2
 * 开放". That made the strip a dead panel: it told the user what to do and then
 * refused to help do it. Now the verbs are live, and the rules that keep them
 * honest are the same three v3 wrote:
 *
 *   - every label reads 建议…, never a past tense (nothing has happened yet);
 *   - confidence is shown, and a low one never reads as a bare imperative;
 *   - delete / unsubscribe carry an extra 不可撤销 marker.
 *
 * The strip never executes anything itself. It calls back into the same write
 * path the row verbs use, so the decision recording and the undo window stay in
 * one place (`App.tsx`), not duplicated here.
 */
import type { ReactNode } from "react";
import type { AdviceRecord } from "../core/types";
import { t } from "../l10n/zh";

const DESTRUCTIVE: ReadonlySet<string> = new Set(["delete", "unsubscribe"]);

/** Actions a click can actually carry out from this strip. */
const EXECUTABLE: ReadonlySet<string> = new Set(["archive", "delete"]);

export interface AdviceStripProps {
  record: AdviceRecord;
  /** Run the suggestion. Absent disables the verb with a reason. */
  onAccept?: () => void;
  /** Dismiss the suggestion without touching the mail. */
  onDismiss?: () => void;
  busy?: boolean;
}

export function AdviceStrip(props: AdviceStripProps): ReactNode {
  const { advice } = props.record;
  const label = t.briefing.advice.actions[advice.action] ?? advice.action;
  const confidence = advice.confidence;
  const confidenceLabel =
    confidence === "high" ? t.briefing.advice.high : confidence === "medium" ? t.briefing.advice.medium : t.briefing.advice.low;
  const destructive = DESTRUCTIVE.has(advice.action);
  // A suggestion this build cannot carry out ("reply", "wait", "remind") says
  // so instead of offering a button that would do the wrong thing.
  const executable = EXECUTABLE.has(advice.action);
  const acceptDisabled = props.busy || !executable || !props.onAccept;
  return (
    <span className="advice">
      <span>{label}</span>
      <span className={"conf " + confidence} title={t.briefing.advice.title}>
        {confidenceLabel}
      </span>
      {destructive ? <span className="chip err">不可撤销</span> : null}
      <span className="spacer" />
      <button
        type="button"
        disabled={acceptDisabled}
        title={
          executable
            ? undefined
            : t.briefing.advice.notBatchable(advice.action)
        }
        onClick={props.onAccept}
      >
        {t.briefing.advice.accept}
      </button>
      <button
        type="button"
        disabled={props.busy || !props.onDismiss}
        onClick={props.onDismiss}
      >
        {t.briefing.advice.dismiss}
      </button>
      {advice.rationale ? <span className="rationale">{t.briefing.advice.why} {advice.rationale}</span> : null}
    </span>
  );
}

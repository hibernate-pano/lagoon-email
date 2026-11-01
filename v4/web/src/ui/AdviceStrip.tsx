/**
 * The AI suggestion inside the row (RowAdviceStrip.swift:4-49).
 *
 * Read-only in M1 and it says so: the two verbs that would *act* (照做 / 忽略)
 * are rendered disabled with "M2 开放" rather than hidden, because a strip that
 * silently loses its buttons reads as a broken panel, while a disabled button
 * with a reason reads as a schedule.
 *
 * Three rules copied from v3 and from the constitution it cites:
 *   - every label reads "建议…", never a past tense (nothing has happened);
 *   - confidence is shown, and a low one never reads as a bare imperative;
 *   - delete / unsubscribe carry an extra "不可撤销" marker.
 */
import type { ReactNode } from "react";
import type { AdviceRecord } from "../core/types";
import { t } from "../l10n/zh";

const DESTRUCTIVE: ReadonlySet<string> = new Set(["delete", "unsubscribe"]);

export function AdviceStrip(props: { record: AdviceRecord }): ReactNode {
  const { advice } = props.record;
  const label = t.briefing.advice.actions[advice.action] ?? advice.action;
  const confidence = advice.confidence;
  const confidenceLabel =
    confidence === "high" ? t.briefing.advice.high : confidence === "medium" ? t.briefing.advice.medium : t.briefing.advice.low;
  const destructive = DESTRUCTIVE.has(advice.action);
  return (
    <span className="advice">
      <span>{label}</span>
      <span className={"conf " + confidence} title={t.briefing.advice.title}>
        {confidenceLabel}
      </span>
      {destructive ? <span className="chip err">不可撤销</span> : null}
      <span className="spacer" />
      <button type="button" disabled title={t.briefing.advice.acceptDisabled}>
        {t.briefing.advice.accept}
      </button>
      <button type="button" disabled title={t.briefing.advice.dismissDisabled}>
        {t.briefing.advice.dismiss}
      </button>
      {advice.rationale ? <span className="rationale">{t.briefing.advice.why} {advice.rationale}</span> : null}
    </span>
  );
}

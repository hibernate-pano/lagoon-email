import { describe, expect, it } from "vitest";
import { zh } from "../../l10n/zh";

/**
 * The empty states of the decision board.
 *
 * These are assertions about *words*, and they exist because of a bug that
 * shipped once: the board said 「没有待决定的事 / 队列清空了」 while the
 * progress line right above it said 「未判 430」. Both sentences were
 * individually reasonable and together they were a lie - the user could see
 * the contradiction without leaving the screen.
 *
 * The rule these pin down: the number of unjudged mails and the emptiness of
 * the queue are different facts, and the copy must never mix them.
 */
describe("the decision board's empty states", () => {
  it("says how many mails nobody has looked at", () => {
    expect(zh.decisions.emptyNotJudged(430)).toContain("430");
    expect(zh.decisions.emptyNotJudged(430)).not.toContain("队列清空");
  });

  it("does not call an unjudged queue empty", () => {
    // The word 「队列清空」 is reserved for the case where it is true.
    expect(zh.decisions.emptyNotJudged(108)).not.toBe(zh.decisions.emptyAllDone);
    expect(zh.decisions.emptyNotJudgedHint).not.toBe(zh.decisions.emptyAllDoneHint);
  });

  it("separates 'nothing to do' from 'nothing looked at'", () => {
    expect(zh.decisions.emptyAllDone).not.toBe(zh.decisions.emptyNotJudged(0));
    expect(zh.decisions.emptyAllDoneHint).toContain("队列清空");
  });

  it("does not claim the rules layer finished before it ran", () => {
    // 「规则那层已经跑完」 is only true after the rules layer has produced
    // something. Before that the sentence has to say what *can* still happen.
    expect(zh.decisions.unconfigured).toContain("已经跑完");
    expect(zh.decisions.unconfiguredBeforeRun).not.toContain("已经跑完");
    expect(zh.decisions.unconfiguredBeforeRun).toContain("免费");
  });

  it("keeps the two unconfigured sentences distinct", () => {
    expect(zh.decisions.unconfigured).not.toBe(zh.decisions.unconfiguredBeforeRun);
  });
});

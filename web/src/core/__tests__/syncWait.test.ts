import { describe, expect, it } from "vitest";

import { roundSettled, syncStateOf } from "../syncWait";
import type { ConnectedAccount } from "../types";

function account(overrides: Partial<ConnectedAccount["syncHealth"]> = {}): ConnectedAccount {
  return {
    id: "acc-1",
    provider: "qq",
    email: "a@example.com",
    isActive: true,
    unreadCount: 0,
    syncHealth: { status: "ok", lastSyncAt: "2026-11-02T10:00:00.000Z", ...overrides },
    capabilities: {},
  } as ConnectedAccount;
}

describe("manual sync settlement", () => {
  it("is still running while the cursor timestamp and status are unchanged", () => {
    const before = syncStateOf([account()], "acc-1");
    expect(before).not.toBeNull();
    expect(roundSettled(before!, syncStateOf([account()], "acc-1"))).toBe(false);
  });

  it("settles when a round writes a new lastSyncAt", () => {
    const before = syncStateOf([account()], "acc-1");
    const after = syncStateOf(
      [account({ lastSyncAt: "2026-11-02T10:00:01.000Z" })],
      "acc-1",
    );
    expect(roundSettled(before!, after)).toBe(true);
  });

  it("settles when the round changes health, even without a new timestamp", () => {
    const before = syncStateOf([account()], "acc-1");
    const after = syncStateOf([account({ status: "error", lastError: "unreachable" })], "acc-1");
    expect(roundSettled(before!, after)).toBe(true);
  });

  it("stops waiting when the account disappears", () => {
    const before = syncStateOf([account()], "acc-1");
    expect(roundSettled(before!, syncStateOf([], "acc-1"))).toBe(true);
  });
});

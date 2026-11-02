import type { ConnectedAccount, SyncHealth } from "./types";

/**
 * The two fields a sync round writes. Watching them is how the UI can tell a
 * completed round from an accepted request that is still running: POST
 * /api/sync answers 204 the moment the round starts, not when it ends.
 */
export interface SyncWatch {
  lastSyncAt?: string | null;
  status: SyncHealth["status"];
}

export function syncStateOf(accounts: ConnectedAccount[], accountId: string): SyncWatch | null {
  const account = accounts.find((candidate) => candidate.id === accountId);
  if (!account) return null;
  return { lastSyncAt: account.syncHealth.lastSyncAt, status: account.syncHealth.status };
}

/** True once the round has written either a new timestamp or a new health state. */
export function roundSettled(before: SyncWatch, current: SyncWatch | null): boolean {
  if (!current) return true;
  if (current.lastSyncAt !== before.lastSyncAt) return true;
  return current.status !== before.status;
}

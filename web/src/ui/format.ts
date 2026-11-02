/**
 * Pure formatting helpers, ported from v3 where v3 got them right.
 *
 * LagoonTypography.rowTimestamp (LagoonTypography.swift:78-88) is the one rule
 * both surfaces share: today → time only; within 7 days → weekday + time;
 * older → month/day. The audit's finding was that the Briefing and the raw list
 * had *two* conventions for one mailbox; copying either one alone would
 * reintroduce that, so this is a direct port of the shared function.
 */

const WEEKDAYS = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];

function pad(value: number): string {
  return value < 10 ? "0" + String(value) : String(value);
}

export function formatRowTimestamp(iso: string, now: Date = new Date()): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const sameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  const time = pad(date.getHours()) + ":" + pad(date.getMinutes());
  if (sameDay) return time;
  const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);
  if (date >= sevenDaysAgo) return WEEKDAYS[date.getDay()] + " " + time;
  return String(date.getMonth() + 1) + "月" + String(date.getDate()) + "日";
}

/**
 * A date a human can read, for the reply header ("在 2026-11-02 15:04，张三
 * <a@b> 写道："). Local time, fixed width: the format is never negotiated with
 * the reader.
 */
export function formatWhen(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const stamp =
    String(date.getFullYear()) + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate());
  return stamp + " " + pad(date.getHours()) + ":" + pad(date.getMinutes());
}

/** SenderAvatar.initials (SenderAvatar.swift:48-69): 2 parts → 2 letters. */export function initialsOf(email: string, displayName?: string | null): string {
  const name = (displayName ?? "").trim();
  if (name) {
    const parts = name.split(/[\s・·]+/).filter(Boolean);
    if (parts.length >= 2) {
      const combined = ((parts[0][0] ?? "") + (parts[1][0] ?? "")).toUpperCase();
      if (combined) return combined;
    } else if (parts.length === 1) {
      const only = parts[0][0];
      if (only) return only.toUpperCase();
    }
  }
  const local = email.split("@")[0] ?? email;
  return (local[0] ?? "?").toUpperCase();
}

/** SenderAvatar.paletteIndex: sum of utf8 bytes % 8. Not a hash, on purpose. */
export function avatarIndex(email: string): number {
  let sum = 0;
  for (const byte of new TextEncoder().encode(email)) sum = (sum + byte) % 65536;
  return sum % 8;
}

export function avatarColorVar(email: string): string {
  return "var(--avatar-" + String(avatarIndex(email)) + ")";
}

export function displayNameOf(message: { fromName?: string | null; fromAddress: string }): string {
  return message.fromName?.trim() || message.fromAddress;
}

export function truncate(text: string, max: number): string {
  return text.length <= max ? text : text.slice(0, max - 1) + "…";
}

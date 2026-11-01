/**
 * The six states, as a type (task-6 §4, docs/V1.0-产品定义与验收标准.md:68-85).
 *
 * v3 has no state machine: 23 views each write their own isLoading / errorBanner /
 * empty branch, and only SearchSheet.swift:381-411 ever factored the rule into a
 * pure function. That is why the audit could find a failed search rendered as
 * "nothing matched". This port has exactly one ladder, and every waiting surface
 * goes through it:
 *
 *   loading -> offline | unavailable | error | empty | ready(+- partial notes)
 *
 * The three "unknowns" are separate on purpose and are NOT states of a fetch:
 *   - not probed != no         -> TriState (unknown / allowed / denied)
 *   - unreadable != absent     -> Outcome.phase === "unavailable" + reason
 *   - never set != set to zero -> optional fields stay undefined, never 0/false
 */
import { t } from "../l10n/zh";
import type { ApiFailureCode, CallResult } from "./api";

export type PartialNote = { tone: "info" | "warning"; text: string };

export type UnavailableReason =
  | "no-account"
  | "not-ready"
  | "not-configured"
  | "capability"
  /** 401: the token is missing or wrong. Not a network error (checklist S5). */
  | "unauthorized";

export type Outcome<T> =
  | { phase: "loading" }
  | { phase: "ready"; data: T; notes: PartialNote[] }
  | { phase: "empty"; data: T; notes: PartialNote[] }
  | {
      phase: "error";
      title: string;
      detail?: string;
      code?: string;
      status?: number;
      cause: ApiFailureCode | "http" | "server";
      retryable: boolean;
    }
  | { phase: "offline"; detail: string }
  | { phase: "unavailable"; reason: UnavailableReason; title: string; detail?: string };

export const loading = <T>(): Outcome<T> => ({ phase: "loading" });

export const unavailable = (
  reason: UnavailableReason,
  title: string,
  detail?: string,
): Outcome<never> => ({ phase: "unavailable", reason, title, detail });

/** Retry is offered only where retrying can change the answer. */
function isRetryable(status: number): boolean {
  return status >= 500 || status === 408 || status === 429;
}

export interface TranslateOptions<T> {
  /** Data that is valid but means "the server answered: nothing here". */
  isEmpty?: (data: T) => boolean;
  notes?: (data: T) => PartialNote[];
  /** Title used when the failure has no better copy. */
  errorTitle: string;
  /** Server error codes that mean "not available here" rather than "it broke". */
  unavailableCodes?: Record<string, { reason: UnavailableReason; title: string; detail?: string }>;
  /** Fill the detail from the server code, when a code-specific sentence exists. */
  describeCode?: (code: string | null, status: number) => string | undefined;
}

/**
 * CallResult -> Outcome.
 *
 * The one rule this function exists to enforce: a transport failure never
 * becomes an empty list, and a 4xx never becomes "offline". Contract §4.2 rule 2
 * says the front-end may not conflate ok:false with a server answer; this is
 * where that rule is implemented once instead of 23 times.
 */
export function fromCall<T>(result: CallResult<T>, options: TranslateOptions<T>): Outcome<T> {
  if (result.kind === "ok") {
    const notes = options.notes?.(result.data) ?? [];
    const empty = options.isEmpty?.(result.data) ?? false;
    return empty
      ? { phase: "empty", data: result.data, notes }
      : { phase: "ready", data: result.data, notes };
  }

  if (result.kind === "fail") {
    if (result.code === "not-ready") {
      return {
        phase: "unavailable",
        reason: "not-ready",
        title: t.six.unavailable,
        detail: result.message,
      };
    }
    // The sidecar is unreachable or silent. That is a failure, not "offline":
    // offline means "the machine has no network", which the browser can tell us
    // (see useOnline) and which is a different sentence to the user.
    return {
      phase: "error",
      title: options.errorTitle,
      detail: result.message,
      cause: result.code,
      retryable: true,
    };
  }

  // HTTP answer. Codes that mean "this is not available here" are surfaced as
  // unavailable, because retrying cannot help.
  const code = result.code;
  const mapped = code ? options.unavailableCodes?.[code] : undefined;
  if (mapped) {
    return { phase: "unavailable", reason: mapped.reason, title: mapped.title, detail: mapped.detail };
  }

  return {
    phase: "error",
    title: options.errorTitle,
    detail: options.describeCode?.(code, result.status) ?? undefined,
    code: code ?? undefined,
    status: result.status,
    cause: "http",
    retryable: isRetryable(result.status),
  };
}

/**
 * The capability gate has three values (MailCapabilities.swift:7-30).
 *
 * v3 rule: `value != false`, i.e. "not probed" reads as *allowed* — the server is
 * the authority and answers 409 when the folder really is missing. Copying that
 * rule is the point: collapsing "not probed" into "no" is the bug that switched
 * archive off for every account connected before the field existed.
 */
export type TriState = "allowed" | "denied" | "unknown";

export function triFromGate(value: boolean | null | undefined): TriState {
  if (value === false) return "denied";
  if (value === true) return "allowed";
  return "unknown";
}

export function triLabel(state: TriState): string {
  if (state === "allowed") return t.reader.capAllowed;
  if (state === "denied") return t.reader.capDenied;
  return t.reader.capUnknown;
}

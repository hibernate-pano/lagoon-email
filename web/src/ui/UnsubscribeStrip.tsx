/**
 * "This sender offers a way out" — the one line that turns a hunt into a click.
 *
 * What it is not: a button that unsubscribes. This app does not POST to a URL a
 * stranger put in a mail header (see `lagoon-mail/src/mime/unsubscribe.rs` for
 * the full argument). What it does is show the destinations the publisher
 * declared, with their **hosts visible**, and hand the chosen one to the system
 * browser — the same route links in a mail body already take (shell
 * `on_navigation` → `open_in_browser`), so there is no new IPC surface and no
 * new request made from inside this process.
 *
 * Three rules this file holds:
 *   - only `https:` and `mailto:` are rendered, whatever the server sends;
 *   - the host is always shown, because "unsubscribe" with no destination is a
 *     button the user cannot judge;
 *   - parsing the stored JSON can fail, and a failure shows nothing rather than
 *     something invented.
 */
import type { ReactNode } from "react";
import type { UnsubscribeLink } from "../core/types";
import { t } from "../l10n/zh";

/** Parse what the server stored; `[]` for anything unusable. */
export function parseUnsubscribeLinks(raw: string | null | undefined): UnsubscribeLink[] {
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];
  const links: UnsubscribeLink[] = [];
  for (const entry of parsed) {
    if (typeof entry !== "object" || entry === null) continue;
    const record = entry as Record<string, unknown>;
    const url = typeof record.url === "string" ? record.url.trim() : "";
    const kind = record.kind;
    if (kind !== "https" && kind !== "mailto") continue;
    if (!url) continue;
    // The server already drops these, but the client is the last gate before a
    // clickable element: a scheme check here costs nothing and means a future
    // server change cannot turn this strip into a javascript: link.
    const lowered = url.toLowerCase();
    if (kind === "https" && !lowered.startsWith("https://")) continue;
    if (kind === "mailto" && !lowered.startsWith("mailto:")) continue;
    links.push({ url, kind, oneClick: record.oneClick === true });
  }
  return links;
}

/** The part of the URL a user needs to see: the host. */
export function hostOf(link: UnsubscribeLink): string {
  if (link.kind === "mailto") {
    return link.url.replace(/^mailto:/i, "").split("?")[0];
  }
  const withoutScheme = link.url.replace(/^https:\/\//i, "");
  return withoutScheme.split(/[/?#]/)[0] || withoutScheme;
}

export function UnsubscribeStrip(props: {
  links?: string | null;
  /** Runs the RFC 8058 POST; absent in surfaces that cannot write. */
  onOneClick?: () => void;
  busy?: boolean;
}): ReactNode {
  const links = parseUnsubscribeLinks(props.links);
  if (links.length === 0) return null;
  // One https destination is the interesting one; a mailto is offered second,
  // and never as an automatic send.
  const primary = links.find((link) => link.kind === "https") ?? links[0];
  const mailto = links.find((link) => link.kind === "mailto");
  return (
    <div className="unsub-strip">
      <span className="muted">{t.reader.unsubscribeOffer}</span>
      <a className="unsub-link" href={primary.url} target="_blank" rel="noreferrer noopener">
        {hostOf(primary)}
      </a>
      {mailto && mailto !== primary ? (
        <>
          <span className="muted">·</span>
          <a className="unsub-link" href={mailto.url}>
            {t.reader.unsubscribeByMail}
          </a>
        </>
      ) : null}
      {primary.oneClick ? (
        props.onOneClick ? (
          // Irreversible, so the button says so; the confirm lives in the caller,
          // which owns the dialog and the error copy.
          <button
            type="button"
            className="btn small"
            disabled={props.busy}
            onClick={props.onOneClick}
          >
            {props.busy ? t.reader.unsubscribeBusy : t.reader.unsubscribeAction}
          </button>
        ) : (
          <span className="chip">{t.reader.unsubscribeOneClick}</span>
        )
      ) : null}
    </div>
  );
}

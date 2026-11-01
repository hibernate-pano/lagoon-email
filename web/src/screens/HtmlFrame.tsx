/**
 * HTML mail, rendered the way v3 renders it: no scripts, no network, sandboxed.
 *
 * v3 (Sources/Lagoon/Views/HTMLMessageView.swift:94-122) guarantees three things
 * and relies on *blocking*, not on sanitising:
 *   1. content JavaScript off             -> here: sandbox with no allow-scripts
 *   2. no origin for relative URLs        -> here: opaque origin + srcdoc
 *   3. every network scheme blocked       -> here: CSP default-src 'none'
 * plus a navigation rule that only a user-clicked main-frame link may leave the
 * app. A Web port cannot reuse WKContentRuleList, so the equivalent is the CSP
 * meta below. The rule is the same: the guarantee is that nothing loads, not
 * that the HTML was cleaned.
 *
 * Inline images: cid: references are replaced by data: URLs before the document
 * is handed to the frame (HTMLMessageView.swift:658-695). The MIME type is taken
 * from the attachment list, then from the file's magic bytes — v3 returns
 * application/octet-stream and lets WebKit sniff; a browser will not render an
 * <img> with that type, so this port does the sniff itself.
 *
 * KNOWN GAP vs v3 (documented in v4/web/README.md): v3 measures the document
 * height and sizes the WebView to it, so there is one scroller. With scripts
 * banned we cannot measure from inside, so the frame has a fixed height and its
 * own scrollbar. Fidelity of scrolling is traded for the privacy rule; the
 * privacy rule is the one that matters.
 */
import type { ReactNode } from "react";

/** Copied verbatim from HTMLMessageView.fluidCSS (HTMLMessageView.swift:480-488). */
export const FLUID_CSS = [
  "html, body { margin: 0; padding: 0; max-width: 100%; }",
  "body { word-wrap: break-word; overflow-wrap: break-word; -webkit-text-size-adjust: 100%; padding: 12px; }",
  "table { max-width: 100% !important; }",
  "img, video { max-width: 100% !important; height: auto !important; }",
  "pre { white-space: pre-wrap; word-wrap: break-word; }",
].join("\n");

const CSP = [
  "default-src 'none'",
  "img-src data: blob:",
  "style-src 'unsafe-inline'",
  "font-src 'none'",
  "media-src 'none'",
  "script-src 'none'",
  "frame-src 'none'",
  "form-action 'none'",
  "base-uri 'none'",
].join("; ");

/** Best-effort mime from the first bytes of a base64 payload. */
function sniffMime(base64: string): string {
  if (base64.startsWith("/9j/")) return "image/jpeg";
  if (base64.startsWith("iVBOR")) return "image/png";
  if (base64.startsWith("R0lGOD")) return "image/gif";
  if (base64.startsWith("UklGR")) return "image/webp";
  if (base64.startsWith("Qk")) return "image/bmp";
  return "application/octet-stream";
}

/**
 * Replace src="cid:xxx" with src="data:<mime>;base64,<bytes>".
 * Case-insensitive on both sides: senders disagree about capitalisation
 * (HTMLMessageView.swift:658-661).
 */
export function resolveCidReferences(
  html: string,
  images: Record<string, string>,
  mimeByCid: Record<string, string>,
): string {
  if (Object.keys(images).length === 0) return html;
  const lookup = new Map<string, string>();
  for (const [key, value] of Object.entries(images)) lookup.set(key.toLowerCase(), value);
  const pattern = /src\s*=\s*["']cid:([^"'>\s]+)["']/gi;
  return html.replace(pattern, (full, rawCid: string) => {
    const cid = String(rawCid).toLowerCase();
    const bytes = lookup.get(cid);
    if (!bytes) return full;
    const mime = mimeByCid[cid] ?? sniffMime(bytes);
    return 'src="data:' + mime + ";base64," + bytes + '"';
  });
}

function wrapDocument(html: string): string {
  const head =
    '<meta charset="utf-8">' +
    '<meta http-equiv="Content-Security-Policy" content="' + CSP + '">' +
    '<meta name="referrer" content="no-referrer">' +
    "<style>" + FLUID_CSS + "</style>";
  if (/<head[^>]*>/i.test(html)) return html.replace(/<head([^>]*)>/i, "<head$1>" + head);
  if (/<html[^>]*>/i.test(html)) return html.replace(/<html([^>]*)>/i, "<html$1><head>" + head + "</head>");
  return "<!doctype html><html><head>" + head + "</head><body>" + html + "</body></html>";
}

export function buildSrcdoc(html: string, images: Record<string, string>, mimeByCid: Record<string, string>): string {
  return wrapDocument(resolveCidReferences(html, images, mimeByCid));
}

export function HtmlFrame(props: { html: string; images: Record<string, string>; mimeByCid: Record<string, string>; title: string }): ReactNode {
  return (
    <iframe
      className="html-frame"
      title={props.title}
      // sandbox="" is the strongest setting: no scripts, no forms, no top
      // navigation, no same-origin. The document cannot talk to the app.
      sandbox=""
      referrerPolicy="no-referrer"
      srcDoc={buildSrcdoc(props.html, props.images, props.mimeByCid)}
    />
  );
}

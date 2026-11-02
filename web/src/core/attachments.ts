/**
 * Attachments: the part that can be decided without a network.
 *
 * A mail attachment is bytes, and `api` carries JSON — so the download goes
 * through a different channel (the shell's `download` command in the app, a
 * Blob in the browser dev build). This module owns what both channels need to
 * agree on: which URL, which name, and whether the part is worth offering.
 */
import type { Attachment } from "./types";

/** The download route for one part. */
export function attachmentPath(remoteId: string, attachmentId: string): string {
  // Both halves are encoded: a remote id is usually a Message-ID (`<a@b>`),
  // and angle brackets in a path are not a path.
  return (
    "/api/messages/" +
    encodeURIComponent(remoteId) +
    "/attachments/" +
    encodeURIComponent(attachmentId)
  );
}

const EXTENSIONS: Record<string, string> = {
  "application/pdf": ".pdf",
  "application/zip": ".zip",
  "application/msword": ".doc",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
  "application/vnd.ms-excel": ".xls",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
  "application/vnd.ms-powerpoint": ".ppt",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
  "application/json": ".json",
  "application/octet-stream": "",
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/gif": ".gif",
  "image/webp": ".webp",
  "text/plain": ".txt",
  "text/csv": ".csv",
  "text/html": ".html",
  "message/rfc822": ".eml",
};

/** A file extension for a type we know; empty when we do not. */
export function extensionFor(mimeType: string): string {
  const base = mimeType.split(";")[0].trim().toLowerCase();
  return EXTENSIONS[base] ?? "";
}

/**
 * The name to save under.
 *
 * The sender's name is kept verbatim (only sanitised) — renaming someone's
 * `README` to `README.txt` would be a small lie about the file. Only a part
 * with no name at all gets a synthesised one, and that one gets the extension
 * the type implies so the Finder knows what it is.
 *
 * It never contains a path separator: the name comes from a mail, and a mail
 * is not trusted.
 */
export function downloadName(attachment: Attachment): string {
  const given = (attachment.filename ?? "").trim();
  if (given) {
    const safe = given
      .replace(/[/\\\u0000-\u001f]/g, "_")
      .replace(/^\.+/, "")
      .trim();
    return safe || "attachment";
  }
  const id = attachment.id.replace(/[^0-9.]/g, "") || "file";
  return "attachment-" + id + extensionFor(attachment.mimeType);
}

/**
 * Whether this part is a picture the body renders in place.
 *
 * A content id is part of the definition: without one there is no `cid:` for
 * the HTML to point at, so the picture can only be seen as a file — and the
 * reader must offer it as one instead of asking the server for an image it can
 * never place.
 */
export function isInlineImage(attachment: Attachment): boolean {
  return (
    attachment.disposition === "inline" &&
    attachment.mimeType.toLowerCase().startsWith("image/") &&
    (attachment.contentId?.trim() ?? "").length > 0
  );
}

/**
 * Whether the reader should offer this part as a download.
 *
 * Pictures the body renders are not files the user asked for. Everything else
 * with an id is downloadable.
 */
export function isDownloadable(attachment: Attachment): boolean {
  return attachment.id.length > 0 && !isInlineImage(attachment);
}

/** A size for the chip: `1.2 MB`, `512 B`. */
export function formatSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "";
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb < 10 ? kb.toFixed(1) : Math.round(kb)} KB`;
  const mb = kb / 1024;
  return `${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`;
}

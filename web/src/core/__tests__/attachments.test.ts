import { describe, expect, it } from "vitest";
import {
  attachmentPath,
  downloadName,
  extensionFor,
  formatSize,
  isDownloadable,
  isInlineImage,
} from "../attachments";
import type { Attachment } from "../types";

function attachment(overrides: Partial<Attachment> = {}): Attachment {
  return {
    id: "1.2",
    filename: "report.pdf",
    mimeType: "application/pdf",
    size: 2048,
    disposition: "attachment",
    ...overrides,
  };
}

describe("attachmentPath", () => {
  it("encodes both halves of the route", () => {
    expect(attachmentPath("<a@b.example>", "1.2")).toBe(
      "/api/messages/%3Ca%40b.example%3E/attachments/1.2",
    );
  });

  it("leaves a plain remote id readable", () => {
    expect(attachmentPath("fixture-msg-1", "1")).toBe(
      "/api/messages/fixture-msg-1/attachments/1",
    );
  });
});

describe("downloadName", () => {
  it("keeps the sender's name", () => {
    expect(downloadName(attachment())).toBe("report.pdf");
  });

  it("keeps a name that has no extension as it is", () => {
    // `README` is the whole name; inventing `.txt` would rename the user's file.
    expect(downloadName(attachment({ filename: "README", mimeType: "text/plain" }))).toBe(
      "README",
    );
  });

  it("names a nameless part after its id and type", () => {
    expect(
      downloadName(attachment({ id: "1.3", filename: null, mimeType: "application/pdf" })),
    ).toBe("attachment-1.3.pdf");
  });

  it("adds the extension a nameless part's type implies", () => {
    expect(
      downloadName(attachment({ id: "2", filename: undefined, mimeType: "image/png" })),
    ).toBe("attachment-2.png");
  });

  it("never lets a path separator through", () => {
    // One component, no leading dots: whatever the sender wrote, the file
    // lands inside the downloads directory.
    expect(downloadName(attachment({ filename: "../../etc/passwd" }))).toBe(
      "_.._etc_passwd",
    );
  });

  it("falls back to a name when everything was stripped", () => {
    expect(downloadName(attachment({ filename: "..", mimeType: "x/y" }))).toBe("attachment");
  });

  it("keeps a name the sender gave, extension or not", () => {
    // Renaming `会议纪要` to `会议纪要.pdf` would be a lie about the file.
    expect(downloadName(attachment({ filename: "会议纪要", mimeType: "application/pdf" }))).toBe(
      "会议纪要",
    );
  });
});

describe("extensionFor", () => {
  it("knows the common types", () => {
    expect(extensionFor("application/pdf")).toBe(".pdf");
    expect(extensionFor("image/jpeg")).toBe(".jpg");
    expect(extensionFor("message/rfc822")).toBe(".eml");
  });

  it("ignores parameters and case", () => {
    expect(extensionFor("TEXT/PLAIN; charset=UTF-8")).toBe(".txt");
  });

  it("does not invent an extension for an unknown type", () => {
    expect(extensionFor("application/x-made-up")).toBe("");
  });
});

describe("isInlineImage", () => {
  it("is a picture the body points at with a cid", () => {
    expect(
      isInlineImage(
        attachment({ disposition: "inline", mimeType: "image/jpeg", contentId: " photo@x " }),
      ),
    ).toBe(true);
  });

  it("is not a picture the sender attached as a file", () => {
    expect(
      isInlineImage(attachment({ disposition: "attachment", mimeType: "image/jpeg" })),
    ).toBe(false);
  });

  it("is not a picture with no cid: nothing can reference it", () => {
    expect(isInlineImage(attachment({ disposition: "inline", mimeType: "image/png" }))).toBe(
      false,
    );
  });

  it("is not a non-image part", () => {
    expect(
      isInlineImage(
        attachment({ disposition: "inline", mimeType: "text/plain", contentId: "a@b" }),
      ),
    ).toBe(false);
  });
});

describe("isDownloadable", () => {
  it("offers a file attachment", () => {
    expect(isDownloadable(attachment())).toBe(true);
  });

  it("does not offer an inline picture that the body can render", () => {
    expect(
      isDownloadable(
        attachment({ disposition: "inline", mimeType: "image/png", contentId: "logo@x" }),
      ),
    ).toBe(false);
  });

  it("offers an inline-typed picture that has no content id", () => {
    // Nothing can render it — there is no `cid:` to point at — so the file is
    // the only way to see it.
    expect(
      isDownloadable(attachment({ disposition: "inline", mimeType: "image/png" })),
    ).toBe(true);
  });

  it("does not offer a part with no id", () => {
    expect(isDownloadable(attachment({ id: "" }))).toBe(false);
  });
});

describe("formatSize", () => {
  it("says nothing about an unknown size", () => {
    expect(formatSize(0)).toBe("");
    expect(formatSize(Number.NaN)).toBe("");
  });

  it("uses the unit that keeps the number short", () => {
    expect(formatSize(512)).toBe("512 B");
    expect(formatSize(2048)).toBe("2.0 KB");
    expect(formatSize(200 * 1024)).toBe("200 KB");
    expect(formatSize(3 * 1024 * 1024)).toBe("3.0 MB");
    expect(formatSize(40 * 1024 * 1024)).toBe("40 MB");
  });
});

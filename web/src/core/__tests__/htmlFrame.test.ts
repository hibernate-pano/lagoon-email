import { describe, expect, it } from "vitest";
import { buildSrcdoc } from "../../screens/HtmlFrame";

/**
 * The CSP is what keeps a mail from loading anything from the network. It is
 * delivered as a <meta> tag, which means it only works if the tag actually
 * lands in the document's real <head>.
 */

function srcdoc(html: string): string {
  return buildSrcdoc(html, {}, {});
}

/** The document as a browser would see it: comments are not content. */
function withoutComments(html: string): string {
  return html.replace(/<!--[\s\S]*?-->/g, "");
}

function hasCspMeta(html: string): boolean {
  return /<meta\s+http-equiv=["']Content-Security-Policy["']/i.test(withoutComments(html));
}

describe("HTML mail CSP", () => {
  it("puts the CSP in the head of a plain document", () => {
    expect(hasCspMeta(srcdoc("<html><head><title>x</title></head><body>hi</body></html>"))).toBe(true);
  });

  it("puts the CSP in the head of a document that has no head", () => {
    expect(hasCspMeta(srcdoc("<p>hi</p>"))).toBe(true);
  });

  it("still applies the CSP when an Outlook conditional comment comes first", () => {
    // The comment's <head> is the first <head> in the string, but it is not a
    // head: it is inside a comment and is never rendered.
    const html = [
      "<!--[if mso]>",
      "<head><style>.mso{color:red}</style></head>",
      "<![endif]-->",
      "<html><head><body><p>hello</p></body></head></html>",
    ].join("\n");
    expect(hasCspMeta(srcdoc(html))).toBe(true);
  });

  it("still applies the CSP when a commented-out head is the only head", () => {
    const html = ["<!-- <head><style>x</style></head> -->", "<html><body>hi</body></html>"].join("\n");
    expect(hasCspMeta(srcdoc(html))).toBe(true);
  });

  it("blocks remote images by policy", () => {
    const doc = srcdoc('<html><head></head><body><img src="https://tracker.example/p.gif"></body></html>');
    expect(doc).toContain("default-src 'none'");
    expect(doc).toContain("img-src data: blob:");
  });

  it("removes a meta refresh so the frame cannot navigate itself away", () => {
    const doc = srcdoc(
      '<html><head><meta http-equiv="refresh" content="0;url=https://tracker.example/beacon"></head><body>hi</body></html>',
    );
    expect(doc).not.toMatch(/http-equiv=["']?refresh/i);
  });

  it("keeps the rest of the document intact", () => {
    const doc = srcdoc("<html><head><title>Subject</title></head><body><p>body text</p></body></html>");
    expect(doc).toContain("<title>Subject</title>");
    expect(doc).toContain("<p>body text</p>");
  });

  it("keeps attributes on the head tag", () => {
    const doc = srcdoc('<html><head lang="zh"><body>hi</body></head></html>');
    expect(doc).toContain('<head lang="zh">');
    expect(hasCspMeta(doc)).toBe(true);
  });
});

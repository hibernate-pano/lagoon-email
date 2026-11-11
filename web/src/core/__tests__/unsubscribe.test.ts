import { describe, expect, it } from "vitest";
import { hostOf, parseUnsubscribeLinks } from "../../ui/UnsubscribeStrip";

describe("what the reader is willing to make clickable", () => {
  it("reads the stored array", () => {
    const links = parseUnsubscribeLinks(
      '[{"url":"https://a.example/u","kind":"https","oneClick":false},{"url":"mailto:u@a.example","kind":"mailto","oneClick":false}]',
    );
    expect(links).toHaveLength(2);
    expect(links[0].kind).toBe("https");
    expect(links[1].kind).toBe("mailto");
  });

  it("treats absent, empty and broken input as no links", () => {
    // Each of the three is a different failure, and all three mean "say nothing"
    // rather than "guess".
    expect(parseUnsubscribeLinks(null)).toEqual([]);
    expect(parseUnsubscribeLinks(undefined)).toEqual([]);
    expect(parseUnsubscribeLinks("")).toEqual([]);
    expect(parseUnsubscribeLinks("[]")).toEqual([]);
    expect(parseUnsubscribeLinks("not json")).toEqual([]);
    expect(parseUnsubscribeLinks('{"url":"https://a.example"}')).toEqual([]);
    expect(parseUnsubscribeLinks('[{"url":"https://a.example","kind":"ftp"}]')).toEqual([]);
  });

  it("refuses a scheme the server should have dropped", () => {
    // The server drops these, but the client is the last gate before an <a>.
    const links = parseUnsubscribeLinks(
      JSON.stringify([
        { url: "javascript:alert(1)", kind: "https" },
        { url: "http://plain.example/u", kind: "https" },
        { url: "data:text/html,x", kind: "https" },
        { url: "https://ok.example/u", kind: "https" },
      ]),
    );
    expect(links).toHaveLength(1);
    expect(links[0].url).toBe("https://ok.example/u");
  });

  it("refuses a mailto that is not a mailto", () => {
    const links = parseUnsubscribeLinks(
      JSON.stringify([{ url: "https://a.example/u", kind: "mailto" }]),
    );
    expect(links).toEqual([]);
  });

  it("drops entries that are not objects", () => {
    const links = parseUnsubscribeLinks('["https://a.example", 42, null]');
    expect(links).toEqual([]);
  });
});

describe("the host the user is asked to trust", () => {
  it("shows the host of an https link, not the whole path", () => {
    expect(hostOf({ url: "https://mail.a.example/u?id=77", kind: "https" })).toBe("mail.a.example");
  });

  it("shows the address of a mailto", () => {
    expect(hostOf({ url: "mailto:leave@a.example", kind: "mailto" })).toBe("leave@a.example");
  });

  it("never renders an empty label", () => {
    // A button with no destination text is a button the user cannot judge.
    expect(hostOf({ url: "https://a.example", kind: "https" })).toBe("a.example");
  });
});

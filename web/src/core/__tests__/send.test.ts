import { describe, expect, it } from "vitest";
import {
  base64ByteLength,
  buildSendBody,
  bytesToBase64,
  draftFor,
  fingerprintOf,
  hasDraftChanges,
  newRequestId,
  requestIdFor,
  sendFailureTitle,
  sendPath,
  validateForm,
  type SendForm,
  type SendOriginal,
} from "../send";

function form(over: Partial<SendForm> = {}): SendForm {
  return { to: "", cc: "", bcc: "", subject: "", body: "", attachments: [], ...over };
}

const original: SendOriginal = {
  remoteId: "42",
  fromAddress: "sender@example.com",
  fromName: "张三",
  subject: "报价",
  receivedAt: "2026-11-02T07:04:00Z",
  when: "2026-11-02 15:04",
  text: "第一行\n第二行",
};

describe("the request id", () => {
  it("is shaped the way the server's strict parser accepts it", () => {
    // The server parses requestId with Uuid::parse_strict: exactly 36
    // characters, hyphens at 8/13/18/23, hex everywhere else.
    const id = newRequestId();
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    expect(id).toHaveLength(36);
  });

  it("is not the same twice", () => {
    const ids = new Set(Array.from({ length: 50 }, () => newRequestId()));
    expect(ids.size).toBe(50);
  });
});

describe("the request body", () => {
  it("gives compose a single recipient string, because that is the shape the route accepts", () => {
    const body = buildSendBody("compose", form({ to: "a@b.com", body: "hi" }), "rid");
    expect(body.to).toBe("a@b.com");
  });

  it("gives reply a recipient list, because the route rejects a string there", () => {
    const body = buildSendBody("reply", form({ to: "a@b.com, c@d.com", body: "hi" }), "rid");
    expect(body.to).toEqual(["a@b.com, c@d.com"]);
  });

  it("gives forward a recipient list too", () => {
    const body = buildSendBody("forward", form({ to: "a@b.com" }), "rid");
    expect(body.to).toEqual(["a@b.com"]);
  });

  it("omits the recipients of a reply when the field is empty, so the server falls back to the sender", () => {
    const body = buildSendBody("reply", form({ body: "hi" }), "rid");
    expect(body.to).toBeUndefined();
  });

  it("never puts attachments on a forward: the original IS the attachment", () => {
    const body = buildSendBody(
      "forward",
      form({
        to: "a@b.com",
        attachments: [{ filename: "x.txt", mimeType: "text/plain", dataBase64: "aGk=" }],
      }),
      "rid",
    );
    expect(body.attachments).toBeUndefined();
  });

  it("carries the attachments of a reply", () => {
    const body = buildSendBody(
      "reply",
      form({
        to: "a@b.com",
        body: "hi",
        attachments: [{ filename: "x.txt", mimeType: "text/plain", dataBase64: "aGk=" }],
      }),
      "rid",
    );
    expect(body.attachments).toHaveLength(1);
  });

  it("carries the requestId on every mode: it is the idempotency key", () => {
    for (const mode of ["reply", "compose", "forward"] as const) {
      expect(buildSendBody(mode, form({ to: "a@b.com", body: "x" }), "rid").requestId).toBe("rid");
    }
  });

  it("leaves out an empty cc/bcc instead of sending empty strings", () => {
    const body = buildSendBody("compose", form({ to: "a@b.com", cc: "  " }), "rid");
    expect(body.cc).toBeUndefined();
  });
});

describe("the form check", () => {
  it("refuses a new mail without a recipient", () => {
    const result = validateForm("compose", form({ body: "hi" }));
    expect(result.ok).toBe(false);
  });

  it("refuses a forward without a recipient", () => {
    const result = validateForm("forward", form({ body: "hi" }));
    expect(result.ok).toBe(false);
  });

  it("refuses an empty reply, because the server answers 400 for it", () => {
    const result = validateForm("reply", form({ to: "a@b.com", body: "   " }));
    expect(result.ok).toBe(false);
  });

  it("accepts an empty body for a new mail", () => {
    expect(validateForm("compose", form({ to: "a@b.com" })).ok).toBe(true);
  });

  it("catches a recipient that is not an address before the server does", () => {
    const result = validateForm("compose", form({ to: "not-an-address" }));
    expect(result.ok).toBe(false);
  });

  it("lets a reply have no recipient: the server then answers the sender", () => {
    expect(validateForm("reply", form({ body: "hi" })).ok).toBe(true);
  });
});

describe("the reply draft", () => {
  it("prefills the recipient, the subject and a quote of the original", () => {
    const draft = draftFor("reply", original);
    expect(draft.to).toBe("sender@example.com");
    expect(draft.subject).toBe("Re: 报价");
    expect(draft.body).toContain("在 2026-11-02 15:04，张三 <sender@example.com> 写道：");
    expect(draft.body).toContain("> 第一行");
  });

  it("does not stack Re: on a subject that already has one", () => {
    const draft = draftFor("reply", { ...original, subject: "RE: 报价" });
    expect(draft.subject).toBe("RE: 报价");
  });

  it("prefixes a forward with Fwd:", () => {
    expect(draftFor("forward", original).subject).toBe("Fwd: 报价");
  });

  it("starts a new mail empty", () => {
    const draft = draftFor("compose");
    expect(draft.to).toBe("");
    expect(draft.subject).toBe("");
    expect(draft.body).toBe("");
  });

  it("quotes nothing it does not have: a body-less original still leaves a reply body", () => {
    const draft = draftFor("reply", { ...original, text: "" });
    expect(draft.body.trim().length).toBeGreaterThan(0);
    expect(draft.body.split("\n").some((line) => line.startsWith("> "))).toBe(false);
  });
});

describe("what closing the composer would throw away", () => {
  it("is nothing for an untouched draft", () => {
    const initial = draftFor("reply", original);
    expect(hasDraftChanges(initial, { ...initial })).toBe(false);
  });

  it("is the quoted original the reply came with? no - that is not typed text", () => {
    const initial = draftFor("reply", original);
    const edited = { ...initial, body: initial.body + "\n补充一句" };
    expect(hasDraftChanges(initial, edited)).toBe(true);
    expect(hasDraftChanges(initial, { ...initial, body: initial.body + "   " })).toBe(false);
  });

  it("is true once anything the user types or attaches changes", () => {
    const initial = form();
    expect(hasDraftChanges(initial, form({ to: "a@b.example" }))).toBe(true);
    expect(hasDraftChanges(initial, form({ cc: "c@d.example" }))).toBe(true);
    expect(hasDraftChanges(initial, form({ bcc: "e@f.example" }))).toBe(true);
    expect(hasDraftChanges(initial, form({ subject: "主题" }))).toBe(true);
    expect(hasDraftChanges(initial, form({ body: "正文" }))).toBe(true);
    expect(
      hasDraftChanges(
        initial,
        form({
          attachments: [{ filename: "a.pdf", mimeType: "application/pdf", dataBase64: "AA==" }],
        }),
      ),
    ).toBe(true);
  });
});

describe("the idempotency key", () => {
  /**
   * A counter that restarts for every test, so the ids are predictable.
   *
   * The prefix is deliberately *not* the one the fixtures use for the previous
   * attempt: with `"id-"` the first mint equalled `last.requestId`, and every
   * "is fresh" assertion below passed even when the implementation reused the
   * old key.
   */
  const freshMint = () => {
    let n = 0;
    return () => "minted-" + String(++n);
  };

  it("is fresh for the first attempt", () => {
    const result = requestIdFor(null, "fp", freshMint());
    expect(result.requestId).toBe("minted-1");
    expect(result.warnDuplicate).toBe(false);
  });

  it("is reused when the last attempt's outcome is unknown and the content did not change", () => {
    const result = requestIdFor(
      { requestId: "id-1", fingerprint: "fp", outcome: "unknown" },
      "fp",
      freshMint(),
    );
    expect(result.requestId).toBe("id-1");
    expect(result.warnDuplicate).toBe(false);
  });

  it("is reused when the server says the send is already in flight", () => {
    const result = requestIdFor(
      { requestId: "id-1", fingerprint: "fp", outcome: "inflight" },
      "fp",
      freshMint(),
    );
    expect(result.requestId).toBe("id-1");
  });

  it("is fresh after a refusal, because the server replays a failed attempt instead of retrying it", () => {
    const result = requestIdFor(
      { requestId: "id-1", fingerprint: "fp", outcome: "refused" },
      "fp",
      freshMint(),
    );
    expect(result.requestId).toBe("minted-1");
  });

  it("is fresh when the content changed, and says the previous mail may still arrive", () => {
    const result = requestIdFor(
      { requestId: "id-1", fingerprint: "fp", outcome: "unknown" },
      "other",
      freshMint(),
    );
    expect(result.requestId).toBe("minted-1");
    expect(result.warnDuplicate).toBe(true);
  });

  it("does not warn when the content changed after a refusal: that mail never went out", () => {
    const result = requestIdFor(
      { requestId: "id-1", fingerprint: "fp", outcome: "refused" },
      "other",
      freshMint(),
    );
    expect(result.warnDuplicate).toBe(false);
  });
});

describe("the content fingerprint", () => {
  it("changes when the body changes", () => {
    expect(fingerprintOf(form({ body: "a" }))).not.toBe(fingerprintOf(form({ body: "b" })));
  });

  it("does not change when only the surrounding blanks move", () => {
    expect(fingerprintOf(form({ to: " a@b.com " }))).toBe(fingerprintOf(form({ to: "a@b.com" })));
  });

  it("changes when an attachment is added", () => {
    const without = fingerprintOf(form({ body: "x" }));
    const with_ = fingerprintOf(
      form({ body: "x", attachments: [{ filename: "a.txt", mimeType: "text/plain", dataBase64: "aGk=" }] }),
    );
    expect(without).not.toBe(with_);
  });

  it("changes when an attachment of the same size is replaced", () => {
    // Same filename, same MIME type, same encoded length; different bytes.
    const original = fingerprintOf(
      form({ attachments: [{ filename: "a.txt", mimeType: "text/plain", dataBase64: "aGk=" }] }),
    );
    const corrected = fingerprintOf(
      form({ attachments: [{ filename: "a.txt", mimeType: "text/plain", dataBase64: "aHI=" }] }),
    );
    expect(original).not.toBe(corrected);
  });
});

describe("the endpoints", () => {
  it("are the three the contract names", () => {
    expect(sendPath("reply", "42")).toBe("/api/messages/42/send");
    expect(sendPath("compose", "42")).toBe("/api/compose/send");
    expect(sendPath("forward", "42")).toBe("/api/messages/42/forward");
  });

  it("escapes a remote id that is not URL-safe", () => {
    expect(sendPath("reply", "a/b")).toBe("/api/messages/a%2Fb/send");
  });
});

describe("an attachment on its way out", () => {
  it("is base64 the server can decode", () => {
    expect(bytesToBase64(new TextEncoder().encode("hi"))).toBe("aGk=");
  });

  it("encodes bytes that are not text", () => {
    expect(bytesToBase64(new Uint8Array([0, 255, 16]))).toBe("AP8Q");
  });

  it("survives a size big enough to blow the argument limit", () => {
    const bytes = new Uint8Array(200_000).fill(65);
    const encoded = bytesToBase64(bytes);
    expect(base64ByteLength(encoded)).toBe(200_000);
  });

  it("measures the decoded size, not the encoded one", () => {
    expect(base64ByteLength("aGk=")).toBe(2);
    expect(base64ByteLength("")).toBe(0);
  });
});

describe("the sentence for a refused send", () => {
  it("names the failure instead of saying something went wrong", () => {
    expect(sendFailureTitle("smtp-auth-failed")).not.toBe("");
    expect(sendFailureTitle("malformed-recipient")).not.toBe("");
  });

  it("still has something to say about a code it has never heard", () => {
    expect(sendFailureTitle("who-knows").length).toBeGreaterThan(0);
    expect(sendFailureTitle(null).length).toBeGreaterThan(0);
  });
});

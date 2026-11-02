import { describe, expect, it } from "vitest";
import { emptyStateFor } from "../empty";
import { codeSentenceFor, describeHttpFailure } from "../errors";
import { classifyFailure } from "../writes";

// Generated from crates/lagoon-api/src/http/*.rs on 2026-11-02.
// Regenerate with:
//   grep -rhoE '"[a-z][a-zA-Z0-9]*(-[a-zA-Z0-9]+)+"' crates/lagoon-api/src/http/*.rs | sort -u
// ...then hand-check that every literal is an error envelope, not a health
// label (e.g. "not-configured" is a sync_state value, not a response code).
const BACKEND_CODES = [
  "account-exists",
  "action-expired",
  "already-undone",
  "api-unauthorized",
  "archive-unavailable",
  "delete-unavailable",
  "draft-unreadable",
  "empty-actionIds",
  "empty-remoteIds",
  "encoding-failed",
  "forbidden-host",
  "imap-auth-failed",
  "imap-unreachable",
  "internal-error",
  "invalid-body",
  "malformed-accountId",
  "malformed-action-id",
  "malformed-before",
  "malformed-decision",
  "malformed-pinned",
  "malformed-remoteId",
  "missing-body",
  "missing-field",
  "not-undoable",
  "provider-auth-failed",
  "provider-not-configured",
  "provider-unreachable",
  "uidplus-missing",
  "undo-failed",
  "unknown-account",
  "unknown-action",
  "unknown-before",
  "unknown-stack",
] as const;

describe("the backend error-code dictionary", () => {
  it("has a human sentence for every code the Rust routes return", () => {
    const missing = BACKEND_CODES.filter((code) => !codeSentenceFor(code));
    expect(missing).toEqual([]);
  });

  it("never answers a backend code with the generic fallback", () => {
    for (const code of BACKEND_CODES) {
      const sentence = describeHttpFailure(code, 500);
      expect(sentence.length).toBeGreaterThan(0);
      expect(sentence.startsWith("服务端返回值")).toBe(false);
    }
  });

  it("keeps the failure taxonomy the write UI reacts to", () => {
    expect(classifyFailure("archive-unavailable", 409)).toBe("capability");
    expect(classifyFailure("already-undone", 409)).toBe("conflict");
    expect(classifyFailure("action-expired", 410)).toBe("gone");
    expect(classifyFailure("unknown-account", 404)).toBe("notfound");
    expect(classifyFailure("api-unauthorized", 401)).toBe("unauthorized");
  });
});

describe("emptyStateFor", () => {
  it("returns the lens copy for a known zero", () => {
    expect(emptyStateFor("inbox", 0)?.title).toBe("收件箱是空的");
    expect(emptyStateFor("trash", 0)?.title).toBe("垃圾箱是空的");
  });
  it("does not treat an unknown total as empty", () => {
    expect(emptyStateFor("inbox", null)).toBeNull();
  });
  it("does not claim an empty state while rows exist", () => {
    expect(emptyStateFor("inbox", 3)).toBeNull();
  });
});

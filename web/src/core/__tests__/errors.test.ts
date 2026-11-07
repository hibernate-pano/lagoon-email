import { describe, expect, it } from "vitest";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { emptyStateFor } from "../empty";
import { codeSentenceFor, describeHttpFailure } from "../errors";
import { classifyFailure } from "../writes";

/**
 * Every error code the Rust routes can put in a response envelope.
 *
 * This is read from the source at test time, not kept as a hand-made list. The
 * list used to be a snapshot taken on one day, which is how `ai-budget-exceeded`
 * slipped through: the backend learned a new code, the dictionary did not, and
 * the test that was supposed to catch it was checking the stale snapshot
 * against itself. Reading the routes means a new code fails this test the day it
 * is written, which is the only version of the guard that keeps working.
 *
 * The pattern is the shape every route uses to answer an error:
 *     respond::error(StatusCode::BAD_REQUEST, "malformed-recipient")
 * spread over one or more lines. `StatusCode::OK` is excluded: "ok" is a health
 * body, not an error envelope.
 */
function backendErrorCodes(): string[] {
  const here = fileURLToPath(new URL(".", import.meta.url));
  const directory = join(here, "../../../../crates/lagoon-api/src/http");
  const codes = new Set<string>();
  const pattern = /StatusCode::(?!OK\b)[A-Z_]+\s*,\s*"([a-z0-9A-Z-]+)"/g;
  for (const file of readdirSync(directory)) {
    if (!file.endsWith(".rs")) continue;
    const source = readFileSync(join(directory, file), "utf8");
    for (const match of source.matchAll(pattern)) codes.add(match[1]);
  }
  return [...codes].sort();
}

const BACKEND_CODES = backendErrorCodes();

describe("the backend error-code dictionary", () => {
  it("found the routes at all", () => {
    // A silent empty list would make every assertion below vacuous.
    expect(BACKEND_CODES.length).toBeGreaterThan(40);
    expect(BACKEND_CODES).toContain("ai-budget-exceeded");
  });

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
    expect(classifyFailure("message-gone", 410)).toBe("gone");
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

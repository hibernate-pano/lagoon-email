import { describe, expect, it } from "vitest";
import { emptyStateFor } from "../empty";

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

import { describe, expect, it } from "vitest";
import { targetIdsOf } from "../selection";

describe("targetIdsOf", () => {
  it("prefers the explicit selection", () => {
    expect(targetIdsOf(new Set(["a", "b"]), "opened", "cursor")).toEqual(["a", "b"]);
  });
  it("falls back to the opened row, then the cursor", () => {
    expect(targetIdsOf(new Set(), "opened", "cursor")).toEqual(["opened"]);
    expect(targetIdsOf(new Set(), null, "cursor")).toEqual(["cursor"]);
  });
  it("is empty when nothing is targeted", () => {
    expect(targetIdsOf(new Set(), null, null)).toEqual([]);
  });
});

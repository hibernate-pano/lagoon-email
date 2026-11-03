import { describe, expect, it, vi } from "vitest";
import {
  canLoadMore,
  debounce,
  DEFAULT_LIST_ROWS,
  isSearching,
  MAX_LIST_ROWS,
  nextListLimit,
  searchNotes,
  searchRequest,
  searchTerm,
} from "../search";
import type { SearchResponse } from "../types";

function response(over: Partial<SearchResponse> = {}): SearchResponse {
  return {
    results: [],
    query: "报价",
    totalCount: 0,
    truncated: false,
    bodyScanSkipped: 0,
    bodyScanLimit: 1000,
    ...over,
  };
}

describe("what counts as a query", () => {
  it("is the trimmed text", () => {
    expect(searchTerm("  报价  ")).toBe("报价");
    expect(searchTerm("   ")).toBe("");
  });

  it("is nothing when the box is empty or only spaces", () => {
    expect(isSearching("")).toBe(false);
    expect(isSearching("   ")).toBe(false);
    expect(isSearching(" 报价 ")).toBe(true);
  });
});

describe("the search request", () => {
  it("asks the server's search route for the whole account", () => {
    const request = searchRequest("acc-1", "  报价  ");
    expect(request.path).toBe("/api/search");
    expect(request.query).toEqual({ accountId: "acc-1", q: "报价" });
  });
});

describe("what the answer says out loud", () => {
  it("says nothing when the answer is complete", () => {
    expect(searchNotes(response())).toEqual([]);
  });

  it("says the result list is capped when it is", () => {
    const notes = searchNotes(response({ truncated: true, totalCount: 42 }));
    expect(notes).toHaveLength(1);
    expect(notes[0].text).toContain("42");
    expect(notes[0].tone).toBe("info");
  });

  it("says how many mails the budget did not reach", () => {
    const notes = searchNotes(response({ bodyScanSkipped: 7 }));
    expect(notes).toHaveLength(1);
    expect(notes[0].text).toContain("7");
    expect(notes[0].tone).toBe("warning");
  });

  it("says both when both are true", () => {
    expect(searchNotes(response({ truncated: true, totalCount: 9, bodyScanSkipped: 3 }))).toHaveLength(2);
  });
});

describe("the list window", () => {
  it("starts at the server's default", () => {
    expect(DEFAULT_LIST_ROWS).toBe(500);
  });

  it("doubles when more is asked for", () => {
    expect(nextListLimit(DEFAULT_LIST_ROWS)).toBe(1000);
  });

  it("never grows past the server's cap", () => {
    expect(nextListLimit(MAX_LIST_ROWS)).toBe(MAX_LIST_ROWS);
    expect(canLoadMore(MAX_LIST_ROWS)).toBe(false);
    expect(canLoadMore(DEFAULT_LIST_ROWS)).toBe(true);
  });
});

describe("the debounce", () => {
  it("runs once, with the last arguments", () => {
    vi.useFakeTimers();
    try {
      const calls: string[] = [];
      const run = debounce((value: string) => calls.push(value), 200);
      run("报");
      run("报价");
      vi.advanceTimersByTime(199);
      expect(calls).toEqual([]);
      vi.advanceTimersByTime(1);
      expect(calls).toEqual(["报价"]);
    } finally {
      vi.useRealTimers();
    }
  });

  it("can be cancelled", () => {
    vi.useFakeTimers();
    try {
      const calls: string[] = [];
      const run = debounce((value: string) => calls.push(value), 200);
      run("报价");
      run.cancel();
      vi.advanceTimersByTime(500);
      expect(calls).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });
});

import { describe, expect, it } from "@effect/vitest";

import {
  isActiveHistoryRequestCursor,
  shouldShowLoadEarlierControl,
} from "./threadHistoryMerge.ts";

describe("threadHistoryMerge", () => {
  it("only applies history responses for the active request cursor", () => {
    expect(isActiveHistoryRequestCursor("cursor-a", { historyCursor: "cursor-a" })).toBe(true);
    expect(isActiveHistoryRequestCursor("cursor-a", { historyCursor: "cursor-b" })).toBe(false);
    expect(isActiveHistoryRequestCursor("cursor-a", { historyCursor: null })).toBe(false);
  });

  it("shows the load-earlier control when history remains or a local error is set", () => {
    expect(
      shouldShowLoadEarlierControl({
        historyCursor: "c",
        hasMoreHistory: true,
        loading: false,
        error: null,
        expanded: false,
        latestLocalTurnOrdinal: null,
      }),
    ).toBe(true);
    expect(
      shouldShowLoadEarlierControl({
        historyCursor: null,
        hasMoreHistory: false,
        loading: false,
        error: "Could not load earlier activity.",
        expanded: true,
        latestLocalTurnOrdinal: null,
      }),
    ).toBe(true);
    expect(
      shouldShowLoadEarlierControl({
        historyCursor: null,
        hasMoreHistory: false,
        loading: false,
        error: null,
        expanded: false,
        latestLocalTurnOrdinal: null,
      }),
    ).toBe(false);
  });
});

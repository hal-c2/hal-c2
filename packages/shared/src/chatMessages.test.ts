import { describe, expect, it } from "vite-plus/test";

import {
  MAX_COLLAPSED_USER_MESSAGE_LENGTH,
  MAX_COLLAPSED_USER_MESSAGE_LINES,
  shouldCollapseUserMessage,
} from "./chatMessages.ts";

describe("shouldCollapseUserMessage", () => {
  it("keeps ordinary prompts expanded", () => {
    expect(shouldCollapseUserMessage("Please fix the terminal layout.")).toBe(false);
  });

  it("collapses prompts beyond the web UI character limit", () => {
    expect(shouldCollapseUserMessage("x".repeat(MAX_COLLAPSED_USER_MESSAGE_LENGTH + 1))).toBe(true);
  });

  it("measures a message by what it shows, not its link destinations", () => {
    const address = `https://example.com/${"a".repeat(680)}`;
    expect(shouldCollapseUserMessage(`See [the rates page](${address}) for details.`)).toBe(false);
    expect(shouldCollapseUserMessage(`[${"x".repeat(601)}](https://example.com)`)).toBe(true);
  });

  it("measures link syntax inside a code span in full, as it is shown", () => {
    const address = `https://example.com/${"a".repeat(680)}`;
    expect(shouldCollapseUserMessage(`See \`[the rates page](${address})\` for details.`)).toBe(
      true,
    );
    // Outside the code span the same link still reads as its label.
    expect(shouldCollapseUserMessage(`See [the rates page](${address}) for details.`)).toBe(false);
  });

  it("collapses prompts beyond the web UI line limit", () => {
    expect(
      shouldCollapseUserMessage(
        Array.from(
          { length: MAX_COLLAPSED_USER_MESSAGE_LINES + 1 },
          (_, index) => `line ${index}`,
        ).join("\n"),
      ),
    ).toBe(true);
  });
});

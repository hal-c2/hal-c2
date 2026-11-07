import { describe, expect, it } from "bun:test";

import { ATTACHMENT_LINK_TTL_MS, createAttachmentPreviews } from "./attachmentPreviews.ts";

describe("createAttachmentPreviews", () => {
  it("keeps a ready link when its refresh fails, and tries again shortly", async () => {
    let now = 0;
    const answers: Array<string | Error> = [
      "https://mc/a?v=1",
      new Error("offline"),
      "https://mc/a?v=2",
    ];
    const previews = createAttachmentPreviews({
      client: {
        getAttachmentUrl: async () => {
          const answer = answers.shift()!;
          if (answer instanceof Error) throw answer;
          return answer;
        },
        getAttachmentImage: async () => null,
      } as never,
      inlineImages: false,
      nowMs: () => now,
      onChange: () => {},
    });

    previews.get("a", "file");
    await previews.settled();
    expect(previews.get("a", "file").link).toEqual({ state: "ready", url: "https://mc/a?v=1" });

    now += ATTACHMENT_LINK_TTL_MS;
    previews.get("a", "file");
    await previews.settled();
    expect(previews.get("a", "file").link).toEqual({ state: "ready", url: "https://mc/a?v=1" });
    // Not asked again on every redraw.
    expect(answers).toHaveLength(1);

    now += 60_000;
    previews.get("a", "file");
    await previews.settled();
    expect(previews.get("a", "file").link).toEqual({ state: "ready", url: "https://mc/a?v=2" });
  });
});

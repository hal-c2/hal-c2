import { describe, expect, it } from "vite-plus/test";
import * as Schema from "effect/Schema";

import {
  SpaceAuthor,
  SpaceBlockInsertInput,
  SpaceBlockMoveInput,
  SpaceCreateInput,
  SpaceDeckCreateInput,
  SpacePageAskAgentInput,
  SpaceSlideMoveInput,
} from "./space.ts";

const decodeCreate = Schema.decodeSync(SpaceCreateInput);
const decodeMove = Schema.decodeUnknownSync(SpaceBlockMoveInput);
const decodeAuthor = Schema.decodeUnknownSync(SpaceAuthor);
const decodeDeck = Schema.decodeUnknownSync(SpaceDeckCreateInput);
const decodeSlideMove = Schema.decodeUnknownSync(SpaceSlideMoveInput);
const decodeAsk = Schema.decodeUnknownSync(SpacePageAskAgentInput);
const decodeInsert = Schema.decodeUnknownSync(SpaceBlockInsertInput);

describe("Space contracts", () => {
  it("refuses a Space with a blank name", () => {
    expect(() => decodeCreate({ name: "  " })).toThrow();
  });

  it("tells moving a block first (null) from moving it last (left out)", () => {
    expect(decodeMove({ spaceId: "s", blockId: "b", afterBlockId: null })).toHaveProperty(
      "afterBlockId",
      null,
    );
    expect(decodeMove({ spaceId: "s", blockId: "b" })).not.toHaveProperty("afterBlockId");
  });

  it("refuses a deck with a blank title", () => {
    expect(() => decodeDeck({ spaceId: "s", title: " " })).toThrow();
  });

  it("tells moving a slide first (null) from moving it last (left out)", () => {
    expect(decodeSlideMove({ spaceId: "s", slideId: "x", afterSlideId: null })).toHaveProperty(
      "afterSlideId",
      null,
    );
    expect(decodeSlideMove({ spaceId: "s", slideId: "x" })).not.toHaveProperty("afterSlideId");
  });

  it("takes a footnote's label and an image's address only as Markdown writes them", () => {
    const at = { spaceId: "s", pageId: "p" };
    expect(decodeInsert({ ...at, kind: "footnote", label: "note-1" })).toHaveProperty(
      "label",
      "note-1",
    );
    expect(() => decodeInsert({ ...at, kind: "footnote", label: "two words" })).toThrow();
    expect(() => decodeInsert({ ...at, kind: "footnote", label: "[1]" })).toThrow();
    expect(decodeInsert({ ...at, kind: "image", url: "https://x.test/a.png" })).toHaveProperty(
      "url",
      "https://x.test/a.png",
    );
    expect(() => decodeInsert({ ...at, kind: "image", url: "a (b).png" })).toThrow();
    expect(() => decodeInsert({ ...at, kind: "image", url: "space-image:abc" })).toThrow();
  });

  it("names the thread of an agent author", () => {
    expect(decodeAuthor({ type: "agent", threadId: "t1" })).toEqual({
      type: "agent",
      threadId: "t1",
    });
    expect(() => decodeAuthor({ type: "agent" })).toThrow();
  });

  it("takes an older client's ask, and one that chose what a turn may", () => {
    const ask = { spaceId: "s", pageId: "p", request: "tidy this" };
    expect(decodeAsk(ask)).toEqual(ask);

    const chosen = decodeAsk({
      ...ask,
      projectId: "docs",
      modelSelection: { instanceId: "codex", model: "gpt-5.5" },
      runtimeMode: "approval-required",
      interactionMode: "plan",
      attachments: [
        {
          type: "image",
          name: "sketch.png",
          mimeType: "image/png",
          sizeBytes: 68,
          dataUrl: "data:image/png;base64,AAAA",
        },
      ],
      context: { version: 1, records: [{ contextId: "c", kind: "skill", name: "review" }] },
    });
    expect(chosen.interactionMode).toBe("plan");
    expect(chosen.attachments).toHaveLength(1);
    expect(() => decodeAsk({ ...ask, interactionMode: "steer" })).toThrow();
  });
});

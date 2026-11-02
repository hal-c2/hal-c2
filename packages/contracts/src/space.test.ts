import { describe, expect, it } from "vite-plus/test";
import * as Schema from "effect/Schema";

import {
  SpaceAuthor,
  SpaceBlockInsertInput,
  SpaceBlockMoveInput,
  SpaceCreateInput,
  SpaceDeckCreateInput,
  SpaceSlideMoveInput,
} from "./space.ts";

const decodeCreate = Schema.decodeSync(SpaceCreateInput);
const decodeMove = Schema.decodeUnknownSync(SpaceBlockMoveInput);
const decodeAuthor = Schema.decodeUnknownSync(SpaceAuthor);
const decodeDeck = Schema.decodeUnknownSync(SpaceDeckCreateInput);
const decodeSlideMove = Schema.decodeUnknownSync(SpaceSlideMoveInput);
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
});

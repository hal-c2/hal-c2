import { describe, expect, it } from "vite-plus/test";
import * as Schema from "effect/Schema";

import {
  SpaceAuthor,
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

  it("names the thread of an agent author", () => {
    expect(decodeAuthor({ type: "agent", threadId: "t1" })).toEqual({
      type: "agent",
      threadId: "t1",
    });
    expect(() => decodeAuthor({ type: "agent" })).toThrow();
  });
});

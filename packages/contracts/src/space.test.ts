import { describe, expect, it } from "vite-plus/test";
import * as Schema from "effect/Schema";

import { SpaceAuthor, SpaceBlockMoveInput, SpaceCreateInput } from "./space.ts";

const decodeCreate = Schema.decodeSync(SpaceCreateInput);
const decodeMove = Schema.decodeUnknownSync(SpaceBlockMoveInput);
const decodeAuthor = Schema.decodeUnknownSync(SpaceAuthor);

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

  it("names the thread of an agent author", () => {
    expect(decodeAuthor({ type: "agent", threadId: "t1" })).toEqual({
      type: "agent",
      threadId: "t1",
    });
    expect(() => decodeAuthor({ type: "agent" })).toThrow();
  });
});

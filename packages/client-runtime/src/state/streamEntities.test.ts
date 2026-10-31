import { describe, expect, it } from "vite-plus/test";

import {
  EMPTY_STREAM_ENTITIES,
  type EntityStreamFrame,
  entitiesOf,
  entityOf,
  foldStreamEntities,
  type StreamEntities,
} from "./streamEntities.ts";

const fold = (frames: ReadonlyArray<EntityStreamFrame>, from = EMPTY_STREAM_ENTITIES) =>
  frames.reduce<StreamEntities>(foldStreamEntities, from);

const snapshot = (
  offset: number,
  rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>,
): EntityStreamFrame => ({ type: "snapshot", part: 0, done: true, offset, rows });

describe("foldStreamEntities", () => {
  it("applies events after the snapshot in order", () => {
    const state = fold([
      snapshot(3, [["page", "p1", { id: "p1", title: "Plan" }]]),
      {
        type: "events",
        events: [
          [4, "page", "p2", { s: { id: "p2", title: "Notes" } }, 0],
          [5, "page", "p1", { s: { title: "Roadmap" } }, 0],
        ],
      },
    ]);
    expect(entitiesOf(state, "page").map((page) => page.title)).toEqual(["Roadmap", "Notes"]);
    expect(state.offset).toBe(5);
    expect(state.ready).toBe(true);
  });

  it("skips events a resumed subscription replays", () => {
    const appended: EntityStreamFrame = {
      type: "events",
      events: [[4, "block", "b1", { s: { id: "b1", text: "Buy" } }, 0]],
    };
    const suffix: EntityStreamFrame = {
      type: "events",
      events: [[5, "block", "b1", { a: { text: " milk" } }, 0]],
    };
    // The resubscription asked from offset 4 but the MC replays from 3.
    const state = fold([snapshot(3, []), appended, suffix, appended, suffix]);
    expect(entityOf(state, "block", "b1")?.text).toBe("Buy milk");
  });

  it("deletes an entity on a delete patch", () => {
    const state = fold([
      snapshot(1, [
        ["page", "p1", { id: "p1" }],
        ["block", "b1", { id: "b1", pageId: "p1" }],
      ]),
      {
        type: "events",
        events: [
          [2, "page", "p1", { d: true }, 0],
          [3, "block", "b1", { d: true }, 0],
        ],
      },
    ]);
    expect(entitiesOf(state, "page")).toEqual([]);
    expect(entitiesOf(state, "block")).toEqual([]);
  });

  it("keeps what it held until a multi-part snapshot is complete, then replaces it", () => {
    const held = fold([snapshot(2, [["page", "old", { id: "old" }]])]);
    const partway = fold(
      [
        { type: "snapshot", part: 0, done: false, offset: 9, rows: [["page", "a", { id: "a" }]] },
        { type: "events", events: [[10, "page", "a", { s: { title: "A" } }, 0]] },
      ],
      held,
    );
    expect(entitiesOf(partway, "page").map((page) => page.id)).toEqual(["old"]);
    const done = fold(
      [{ type: "snapshot", part: 1, done: true, offset: 10, rows: [["page", "b", { id: "b" }]] }],
      partway,
    );
    expect(entitiesOf(done, "page")).toEqual([{ id: "a", title: "A" }, { id: "b" }]);
  });

  it("starts over on a fresh snapshot after a reconnect", () => {
    const before = fold([
      snapshot(5, [["page", "p1", { id: "p1" }]]),
      { type: "events", events: [[6, "page", "p2", { s: { id: "p2" } }, 0]] },
    ]);
    // The pages were deleted while the client was away; the new session's snapshot says so.
    const after = fold([snapshot(8, [["page", "p3", { id: "p3" }]])], before);
    expect(entitiesOf(after, "page").map((page) => page.id)).toEqual(["p3"]);
    expect(after.offset).toBe(8);
  });
});

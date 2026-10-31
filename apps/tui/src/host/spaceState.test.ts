import { describe, expect, test } from "bun:test";
import type { EntityStreamFrame } from "@hal-c2/client-runtime/state/stream-entities";

import type { PickRequest } from "./composerState.ts";
import {
  createSpaceController,
  refusalText,
  type TuiSpaceRow,
  type TuiSpaceState,
} from "./spaceState.ts";

const at = "2026-07-15T12:00:00.000Z";
const user = { type: "user" } as const;

const space = (id: string, name: string) =>
  ["space", id, { id, name, createdAt: at, updatedAt: at }] as const;
const page = (id: string, title: string, fields: Record<string, unknown> = {}) =>
  [
    "page",
    id,
    {
      id,
      spaceId: "s1",
      title,
      parentPageId: null,
      sourceThreadId: null,
      trashedAt: null,
      createdAt: at,
      updatedAt: at,
      ...fields,
    },
  ] as const;
const block = (id: string, pageId: string, text: string, order: string) =>
  [
    "block",
    id,
    {
      id,
      pageId,
      kind: "paragraph",
      text,
      checked: false,
      linkedPageId: null,
      order,
      createdBy: user,
      updatedBy: user,
      createdAt: at,
      updatedAt: at,
    },
  ] as const;

const snapshot = (
  offset: number,
  rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>,
): EntityStreamFrame => ({ type: "snapshot", part: 0, done: true, offset, rows });

const events = (
  ...list: Array<readonly [number, string, string, Record<string, unknown>]>
): EntityStreamFrame => ({
  type: "events",
  events: list.map(([seq, kind, id, patch]) => [seq, kind, id, patch as never, 0] as const),
});

/** A controller on a client whose streams and replies the test drives by hand. */
function setup() {
  const streams = new Map<string, Array<(frame: EntityStreamFrame) => void>>();
  const replies = new Map<string, Array<(value: unknown) => void>>();
  const calls: Array<{ method: string; payload: unknown }> = [];
  const statuses: string[] = [];
  const menus: PickRequest[] = [];
  let state: TuiSpaceState | null = null;
  const controller = createSpaceController({
    client: {
      mcCall: <T>(method: string, payload: unknown) => {
        calls.push({ method, payload });
        if (method === "space.list") return Promise.resolve({ spaces: [] } as T);
        return new Promise<T>((resolve) => {
          const waiting = replies.get(method) ?? [];
          waiting.push(resolve as (value: unknown) => void);
          replies.set(method, waiting);
        });
      },
      subscribeMcStream: (stream, onFrame) => {
        const list = streams.get(stream) ?? [];
        list.push(onFrame);
        streams.set(stream, list);
        return () => {};
      },
    },
    height: () => 30,
    width: () => 80,
    setOpen: () => {},
    publish: (next) => {
      state = next;
    },
    status: (text) => statuses.push(text),
    ask: () => {},
    menu: (spec) => menus.push(spec),
    threads: () => [{ id: "t1", title: "Work" }],
  });
  /** Send a frame on `stream`; `subscription` picks an older follow of the same stream. */
  const send = (stream: string, frame: EntityStreamFrame, subscription = -1) =>
    streams.get(stream)!.at(subscription)!(frame);
  const reply = (method: string, value: unknown) => replies.get(method)!.shift()!(value);
  const view = () => state!;
  const texts = (kind: TuiSpaceRow["kind"]) =>
    view()
      .rows.filter((row) => row.kind === kind && row.first)
      .map((row) => row.text.slice(2).trim());
  const select = (key: string) => controller.dispatch("space.select", { key });
  return { controller, send, reply, view, texts, select, calls, statuses, menus, streams };
}

/** Open the Spaces, and the Space s1 ("Research") with its pages. */
function inResearch(rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>) {
  const t = setup();
  t.controller.dispatch("space.open", {});
  t.send("spaces", snapshot(1, [space("s1", "Research")]));
  t.select("space:s1");
  t.controller.dispatch("space.activate", {});
  t.send("space:s1", snapshot(10, rows));
  return t;
}

describe("the Space's stream", () => {
  test("an event the pane already holds, replayed after a resume, does not undo a later one", () => {
    const t = inResearch([page("p1", "Roadmap"), page("p2", "Ideas")]);
    t.send("space:s1", events([11, "page", "p1", { d: true }]));
    expect(t.texts("page")).toEqual(["Ideas"]);
    // A resumed subscription replays from an older offset: the page it made comes again.
    t.send("space:s1", events([9, "page", "p1", { s: page("p1", "Roadmap")[2] }]));
    expect(t.texts("page")).toEqual(["Ideas"]);
    t.send("space:s1", events([12, "page", "p2", { s: { title: "Plans" } }]));
    expect(t.texts("page")).toEqual(["Plans"]);
  });

  test("a fresh snapshot after a reconnection replaces what was held", () => {
    const t = inResearch([page("p1", "Roadmap"), page("p2", "Ideas")]);
    // While the client was away, Ideas was deleted for good and Notes made.
    t.send("space:s1", snapshot(20, [page("p1", "Roadmap"), page("p3", "Notes")]));
    expect(t.texts("page")).toEqual(["Roadmap", "Notes"]);
  });

  test("a page deleted while open steps back to the tree, the selection on a page still there", () => {
    const t = inResearch([
      page("p1", "Roadmap"),
      page("p2", "Ideas"),
      block("b1", "p2", "Ship it", "i"),
    ]);
    t.select("page:p2");
    t.controller.dispatch("space.activate", {});
    expect(t.view().view).toBe("page");
    expect(t.texts("block")).toEqual(["Ship it"]);
    t.send("space:s1", events([11, "page", "p2", { d: true }], [12, "block", "b1", { d: true }]));
    expect(t.view().view).toBe("pages");
    expect(t.view().rows.find((row) => row.selected)?.key).toBe("page:p1");
  });

  test("the open Space deleted elsewhere steps back to the Spaces", () => {
    const t = inResearch([]);
    t.send("spaces", events([2, "space", "s1", { d: true }]));
    expect(t.view().view).toBe("spaces");
    expect(t.statuses.at(-1)).toBe("The Space was deleted.");
  });

  test("frames of a Space the pane left do not reach the one it opened", () => {
    const t = inResearch([page("p1", "Roadmap")]);
    t.send("spaces", events([2, "space", "s2", { s: space("s2", "Lab")[2] }]));
    t.controller.dispatch("space.back", {});
    t.select("space:s2");
    t.controller.dispatch("space.activate", {});
    t.send("space:s2", snapshot(3, [["page", "q1", { ...page("q1", "Bench")[2], spaceId: "s2" }]]));
    // The old follow of Research still delivers a frame: it is dropped.
    t.send("space:s1", events([11, "page", "p9", { s: page("p9", "Stray")[2] }]), 0);
    expect(t.view().title).toBe("space · Lab");
    expect(t.texts("page")).toEqual(["Bench"]);
  });
});

describe("replies that come after the user moved on", () => {
  test("a page written from a thread does not open once the user left the Space", async () => {
    const t = inResearch([]);
    t.controller.dispatch("space.fromThread", {});
    t.menus.at(-1)!.onChoose("t1");
    expect(t.statuses.at(-1)).toBe("Writing a page from “Work”…");
    t.controller.dispatch("space.back", {});
    t.reply("space.page.createFromThread", { page: page("p5", "Release plan")[2] });
    await t.controller.settled();
    expect(t.statuses.at(-1)).toBe("Wrote “Release plan”.");
    expect(t.view().view).toBe("spaces");
  });

  test("the same reply opens the page while the user is still in the Space", async () => {
    const t = inResearch([]);
    t.controller.dispatch("space.fromThread", {});
    t.menus.at(-1)!.onChoose("t1");
    t.send("space:s1", events([11, "page", "p5", { s: page("p5", "Release plan")[2] }]));
    t.reply("space.page.createFromThread", { page: page("p5", "Release plan")[2] });
    await t.controller.settled();
    expect(t.view().title).toBe("page · Release plan");
  });
});

describe("refusalText", () => {
  test("names text generation that is unavailable, wherever the client put the detail", () => {
    const error = Object.assign(new Error("No provider is set up."), {
      cause: { detail: { _tag: "SpaceTextGenerationError", reason: "unavailable" } },
    });
    expect(refusalText(error)).toBe(
      "Text generation is unavailable, so no page was made: No provider is set up.",
    );
  });

  test("passes the MC's own words through for any other refusal", () => {
    const error = Object.assign(new Error("A page cannot move inside itself."), {
      detail: { _tag: "SpaceError", reason: "cycle" },
    });
    expect(refusalText(error)).toBe("A page cannot move inside itself.");
  });
});

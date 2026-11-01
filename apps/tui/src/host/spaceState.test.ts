import { describe, expect, test } from "bun:test";
import type { EntityStreamFrame } from "@hal-c2/client-runtime/state/stream-entities";

import type { PickRequest } from "./composerState.ts";
import {
  createSpaceController,
  imageTypeOf,
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

const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** A controller on a client whose streams and replies the test drives by hand. */
function setup() {
  const streams = new Map<string, Array<(frame: EntityStreamFrame) => void>>();
  const replies = new Map<string, Array<(value: unknown) => void>>();
  const calls: Array<{ method: string; payload: unknown }> = [];
  const statuses: string[] = [];
  const menus: PickRequest[] = [];
  const opened: string[] = [];
  const asks: Array<(answer: string) => void> = [];
  const uploads = { fails: false, sent: 0 };
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
      uploadToMc: async () => {
        if (uploads.fails) throw new Error("The MC refused the upload (413).");
        uploads.sent += 1;
      },
    },
    readLocalBytes: async () => PNG,
    height: () => 30,
    width: () => 80,
    setOpen: () => {},
    publish: (next) => {
      state = next;
    },
    status: (text) => statuses.push(text),
    ask: (spec) => asks.push(spec.onSubmit),
    menu: (spec) => menus.push(spec),
    threads: () => [{ id: "t1", title: "Work" }],
    openThread: (threadId) => opened.push(threadId),
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
  return {
    controller,
    send,
    reply,
    view,
    texts,
    select,
    calls,
    statuses,
    menus,
    asks,
    uploads,
    streams,
    opened,
  };
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

describe("a page's history", () => {
  const version = (n: number, fields: Record<string, unknown> = {}) => ({
    version: n,
    at,
    author: user,
    threadTitle: null,
    restoredFromAt: null,
    ...fields,
  });
  const onRoadmap = (fields: Record<string, unknown> = {}) => {
    const t = inResearch([page("p1", "Roadmap", fields), block("b1", "p1", "Final", "a")]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    t.controller.dispatch("space.history", {});
    return t;
  };

  test("is asked for from the tree too, and going back lands on the page", async () => {
    const t = inResearch([page("p1", "Roadmap")]);
    t.select("page:p1");
    t.controller.dispatch("space.history", {});
    expect(t.view().title).toBe("history · Roadmap");
    t.reply("space.page.history", { versions: [version(2)], nextBefore: null });
    await t.controller.settled();
    t.controller.dispatch("space.back", {});
    expect(t.view().title).toBe("page · Roadmap");
  });

  test("loads more a stretch at a time", async () => {
    const t = onRoadmap();
    t.reply("space.page.history", { versions: [version(9), version(8)], nextBefore: 8 });
    await t.controller.settled();
    expect(t.texts("more")).toEqual(["Load more…"]);
    t.select("more:more");
    t.controller.dispatch("space.activate", {});
    t.reply("space.page.history", { versions: [version(7)], nextBefore: null });
    await t.controller.settled();
    expect(t.calls.at(-1)!.payload).toEqual(expect.objectContaining({ before: 8 }));
    expect(t.view().rows.filter((row) => row.kind === "version")).toHaveLength(3);
    expect(t.texts("more")).toEqual([]);
  });

  test("a reply for a history the user left is dropped", async () => {
    const t = onRoadmap();
    t.controller.dispatch("space.back", {});
    t.reply("space.page.history", { versions: [version(9)], nextBefore: null });
    await t.controller.settled();
    expect(t.view().view).toBe("page");
    t.controller.dispatch("space.history", {});
    expect(t.view().rows).toEqual([]);
    expect(t.view().message).toBe("Loading…");
  });

  test("a refresh asked for while one is in flight goes after it", async () => {
    const t = onRoadmap();
    t.controller.dispatch("space.history", {});
    expect(t.calls.filter((call) => call.method === "space.page.history")).toHaveLength(1);
    t.reply("space.page.history", { versions: [version(9)], nextBefore: null });
    await Promise.resolve();
    await Promise.resolve();
    t.reply("space.page.history", { versions: [version(10), version(9)], nextBefore: null });
    await t.controller.settled();
    expect(t.calls.filter((call) => call.method === "space.page.history")).toHaveLength(2);
    expect(t.view().rows.filter((row) => row.kind === "version")).toHaveLength(2);
  });

  test("a refresh past what the MC sends at once keeps the older versions", async () => {
    const t = onRoadmap();
    t.reply("space.page.history", { versions: [version(9), version(8)], nextBefore: 8 });
    await t.controller.settled();
    t.select("more:more");
    t.controller.dispatch("space.activate", {});
    t.reply("space.page.history", { versions: [version(7), version(6)], nextBefore: 6 });
    await t.controller.settled();
    t.controller.dispatch("space.history", {});
    t.reply("space.page.history", { versions: [version(10), version(9)], nextBefore: 9 });
    await t.controller.settled();
    const versions = t.view().rows.filter((row) => row.kind === "version");
    expect(versions.map((row) => row.key)).toEqual([
      "version:10",
      "version:9",
      "version:8",
      "version:7",
      "version:6",
    ]);
    expect(t.view().rows.some((row) => row.kind === "more")).toBe(true);
  });

  test("a version being read cannot be edited", async () => {
    const t = onRoadmap();
    t.reply("space.page.history", { versions: [version(9), version(8)], nextBefore: null });
    await t.controller.settled();
    t.select("version:8");
    t.controller.dispatch("space.activate", {});
    t.reply("space.page.version", {
      version: 8,
      at,
      title: "Roadmap",
      blocks: [block("b1", "p1", "Draft", "a")[2]],
    });
    await t.controller.settled();
    expect(t.view().view).toBe("version");
    const asked = t.calls.length;
    for (const action of ["space.edit", "space.delete", "space.tick", "space.move"]) {
      t.controller.dispatch(action, {});
    }
    t.controller.dispatch("space.activate", {});
    expect(t.calls).toHaveLength(asked);
  });

  test("the newest version is not restored over itself", async () => {
    const t = onRoadmap();
    t.reply("space.page.history", { versions: [version(9), version(8)], nextBefore: null });
    await t.controller.settled();
    t.select("version:9");
    t.controller.dispatch("space.restore", {});
    expect(t.statuses.at(-1)).toBe("This version is the page as it is.");
    expect(t.calls.some((call) => call.method === "space.page.restoreVersion")).toBe(false);
  });

  test("a comment whose block a restore took away is still shown", () => {
    const comment = {
      id: "c1",
      pageId: "p1",
      blockId: "gone",
      author: user,
      body: "Why?",
      resolvedAt: null,
      createdAt: at,
      updatedAt: at,
    };
    const t = inResearch([page("p1", "Roadmap"), ["comment", "c1", comment]]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    expect(t.texts("comment")[0]).toContain("Why? · on a block no longer on this page");
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

describe("a page's agent", () => {
  const agent = (fields: Record<string, unknown> = {}) =>
    [
      "pageAgent",
      "p1",
      {
        id: "p1",
        pageId: "p1",
        threadId: "t1",
        request: "tidy this",
        status: "running",
        edited: false,
        error: null,
        startedAt: at,
        endedAt: null,
        ...fields,
      },
    ] as const;

  const onRoadmap = (...rows: Array<readonly [string, string, Record<string, unknown>]>) => {
    const t = inResearch([page("p1", "Roadmap"), ...rows]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    return t;
  };

  test("it can open the thread it runs in, and says when that thread is gone", () => {
    const t = onRoadmap(agent());
    t.controller.dispatch("space.openAgentThread", {});
    expect(t.opened).toEqual(["t1"]);
    t.send("space:s1", events([11, "pageAgent", "p1", { s: { threadId: "gone" } }]));
    expect(t.view().message).toContain("o opens its thread");
    t.controller.dispatch("space.openAgentThread", {});
    expect(t.opened).toEqual(["t1"]);
    expect(t.statuses).toEqual(["The agent's thread is not available."]);
  });

  test("a second ask is not started while one is working", () => {
    const t = onRoadmap(agent());
    t.controller.dispatch("space.askAgent", {});
    expect(t.statuses).toEqual(["An agent is already working on this page: s stops it."]);
  });

  test("a page without an agent has nothing to stop", () => {
    const t = onRoadmap();
    t.controller.dispatch("space.stopAgent", {});
    expect(t.calls.some((call) => call.method === "space.page.stopAgent")).toBe(false);
    expect(t.statuses).toEqual(["No agent was asked on this page: g asks one."]);
  });

  test("a long request is clipped, and the rows make room for a wrapped message", () => {
    const blocks = Array.from({ length: 40 }, (_, index) =>
      block(`b${index}`, "p1", `Block ${index}`, `a${String(index).padStart(2, "0")}`),
    );
    const t = onRoadmap(...blocks, agent({ request: "tidy ".repeat(100) }));
    const said = t.view().message;
    expect(said.length).toBeLessThan(120);
    expect(said).toContain("…");
    const fitsOneLine = onRoadmap(...blocks).view().rows.length;
    expect(t.view().rows.length).toBeLessThan(fitsOneLine);
  });

  test("the palette offers the way out that fits what the agent is doing", () => {
    const titles = (t: ReturnType<typeof onRoadmap>) =>
      t.controller.commands().map((command) => command.action);
    const working = titles(onRoadmap(agent()));
    expect(working).toContain("space.stopAgent");
    expect(working).not.toContain("space.askAgent");
    const ended = titles(onRoadmap(agent({ status: "completed", endedAt: at })));
    expect(ended).toContain("space.dismissAgent");
    expect(ended).toContain("space.askAgent");
    expect(titles(onRoadmap())).not.toContain("space.openAgentThread");
  });
});

describe("images", () => {
  const image = (id: string, name: string, trashedAt: string | null = null) =>
    ["image", id, { id, spaceId: "s1", name, prompt: null, trashedAt }] as const;
  const placed = (id: string, imageId: string, text: string) =>
    ["block", id, { ...block(id, "p1", text, id)[2], kind: "image", imageId }] as const;
  const onPage = (rows: Parameters<typeof inResearch>[0]) => {
    const t = inResearch([page("p1", "Roadmap"), ...rows]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    return t;
  };

  test("a page puts what a terminal cannot draw in words, caption and all", () => {
    const t = onPage([
      image("i1", "cat.png"),
      image("i2", "dog.png", "2026-07-15T12:00:00.000Z"),
      placed("a", "i1", "cat.png"),
      placed("b", "i1", "the family cat"),
      placed("c", "i2", "dog.png"),
      placed("d", "gone", "fox.png"),
    ]);
    expect(t.texts("block")).toEqual([
      "[image: cat.png]",
      "[image: cat.png] the family cat",
      "[image: dog.png is in the trash]",
      "[image: fox.png was deleted]",
    ]);
  });

  test("Esc from the images goes back to where they were opened", () => {
    const t = onPage([]);
    t.controller.dispatch("space.images", {});
    expect(t.view().view).toBe("images");
    t.controller.dispatch("space.back", {});
    expect(t.view().view).toBe("page");
  });

  test("an upload that fails says so and adds nothing", async () => {
    const t = inResearch([]);
    t.controller.dispatch("space.images", {});
    t.controller.dispatch("space.import", {});
    t.uploads.fails = true;
    t.asks.at(-1)!("/home/me/cat.png");
    await Bun.sleep(0);
    t.reply("attachments.createUploadUrl", { attachmentId: "a1", relativeUrl: "/up/a1" });
    await t.controller.settled();
    expect(t.statuses.at(-1)).toBe("The MC refused the upload (413).");
    expect(t.calls.map((call) => call.method)).not.toContain("space.image.add");
  });

  test("the content of a file decides its type, not its name", () => {
    const ascii = (text: string) => new TextEncoder().encode(text);
    expect(imageTypeOf(PNG)).toBe("image/png");
    expect(imageTypeOf(Uint8Array.from([0xff, 0xd8, 0xff, 0xe0]))).toBe("image/jpeg");
    expect(imageTypeOf(ascii("GIF89a"))).toBe("image/gif");
    expect(imageTypeOf(ascii("RIFF\0\0\0\0WEBPVP8 "))).toBe("image/webp");
    expect(imageTypeOf(ascii("<svg xmlns='http://www.w3.org/2000/svg'/>"))).toBeNull();
    expect(imageTypeOf(ascii("only words"))).toBeNull();
  });

  test("names image generation that failed", () => {
    const error = Object.assign(new Error("No file."), {
      detail: { _tag: "SpaceImageGenerationError", reason: "failed" },
    });
    expect(refusalText(error)).toBe("Image generation failed, so no image was made: No file.");
  });
});

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

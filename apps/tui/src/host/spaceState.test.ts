import { describe, expect, test } from "bun:test";
import type { SpacePresenceViewer } from "@hal-c2/contracts";
import type { EntityStreamFrame } from "@hal-c2/client-runtime/state/stream-entities";

import type { AskSpec } from "./askState.ts";
import type { PickRequest } from "./composerState.ts";
import { memoryMutedThreads } from "./mutedThreads.ts";
import {
  createSpaceController,
  imageTypeOf,
  type SpaceControllerOptions,
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
function setup(origin?: string, extra: Partial<SpaceControllerOptions> = {}) {
  const streams = new Map<string, Array<(frame: EntityStreamFrame) => void>>();
  const replies = new Map<string, Array<(value: unknown) => void>>();
  const refusals = new Map<string, Array<(error: unknown) => void>>();
  const calls: Array<{ method: string; payload: unknown }> = [];
  const statuses: string[] = [];
  const menus: PickRequest[] = [];
  const opened: string[] = [];
  const onPage = new Set<string>();
  const tellPage: Array<(viewers: ReadonlyArray<SpacePresenceViewer>) => void> = [];
  const asks: AskSpec[] = [];
  const uploads = { fails: false, sent: 0 };
  const lists = { fails: false };
  // What `space.files.list` answers for every project, unless a test answers it by hand.
  const projectFiles = { byHand: false, paths: [] as string[] };
  let state: TuiSpaceState | null = null;
  const controller = createSpaceController({
    client: {
      mcCall: <T>(method: string, payload: unknown) => {
        calls.push({ method, payload });
        if (method === "space.list") {
          if (lists.fails) return Promise.reject(new Error("The connection to the MC was lost."));
          return Promise.resolve({ spaces: [] } as T);
        }
        if (method === "space.page.agentTarget") return Promise.resolve({ projectId: "p1" } as T);
        if (method === "space.files.list" && !projectFiles.byHand) {
          const files = projectFiles.paths.map((relativePath) => ({
            relativePath,
            kind: "page",
            page: null,
          }));
          return Promise.resolve({ config: "default", files, spaceId: null } as T);
        }
        return new Promise<T>((resolve, reject) => {
          const waiting = replies.get(method) ?? [];
          waiting.push(resolve as (value: unknown) => void);
          replies.set(method, waiting);
          const failing = refusals.get(method) ?? [];
          failing.push(reject);
          refusals.set(method, failing);
        });
      },
      subscribeMcStream: (stream, onFrame) => {
        const list = streams.get(stream) ?? [];
        list.push(onFrame);
        streams.set(stream, list);
        return () => {};
      },
      subscribeSpacePresence: (_spaceId, pageId, onViewers) => {
        onPage.add(pageId);
        tellPage.push(onViewers);
        return () => {
          onPage.delete(pageId);
        };
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
    ask: (spec) => asks.push(spec),
    menu: (spec) => menus.push(spec),
    threads: () => [{ id: "t1", title: "Work" }],
    projects: () => [{ id: "p1", title: "shop" }],
    openThread: (threadId) => opened.push(threadId),
    ...(origin ? { origin } : {}),
    ...extra,
  });
  /** Send a frame on `stream`; `subscription` picks an older follow of the same stream. */
  const send = (stream: string, frame: EntityStreamFrame, subscription = -1) =>
    streams.get(stream)!.at(subscription)!(frame);
  const reply = (method: string, value: unknown) => {
    refusals.get(method)!.shift();
    replies.get(method)!.shift()!(value);
  };
  const refuse = (method: string, error: unknown) => {
    replies.get(method)!.shift();
    refusals.get(method)!.shift()!(error);
  };
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
    refuse,
    view,
    texts,
    select,
    calls,
    statuses,
    menus,
    asks,
    uploads,
    lists,
    projectFiles,
    streams,
    opened,
    onPage,
    tellPage,
  };
}

/** Open the Spaces, and the Space s1 ("Research") with its pages. */
function inResearch(
  rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>,
  origin?: string,
  extra: Partial<SpaceControllerOptions> = {},
) {
  const t = setup(origin, extra);
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

describe("who else is on the page", () => {
  const onRoadmap = () => {
    const t = inResearch([page("p1", "Roadmap")]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    return t;
  };

  test("the pages of a Space are not being on a page", () => {
    expect(inResearch([page("p1", "Roadmap")]).onPage.size).toBe(0);
  });

  test("a page deleted while open is left", () => {
    const t = onRoadmap();
    expect([...t.onPage]).toEqual(["p1"]);
    t.send("space:s1", events([11, "page", "p1", { d: true }]));
    expect(t.onPage.size).toBe(0);
  });

  test("closing the pane leaves the page and forgets who was on it", () => {
    const t = onRoadmap();
    t.tellPage[0]!([{ type: "user", devices: ["Phone"] }]);
    expect(t.view().viewers).toBe("Also here: Phone");
    t.controller.close();
    expect(t.onPage.size).toBe(0);
    expect(t.view().viewers).toBe("");
  });

  test("a lost connection forgets who was on the page until the MC says again", () => {
    const t = onRoadmap();
    t.tellPage[0]!([{ type: "user", devices: ["Phone"] }]);
    t.controller.connectionLost();
    expect(t.view().viewers).toBe("");
    expect([...t.onPage]).toEqual(["p1"]);
    t.tellPage[0]!([{ type: "user", devices: ["Laptop"] }]);
    expect(t.view().viewers).toBe("Also here: Laptop");
  });

  test("a late answer for a page the user left does not reach the next", () => {
    const t = onRoadmap();
    t.controller.dispatch("space.back", {});
    t.tellPage[0]!([{ type: "user", devices: ["Phone"] }]);
    expect(t.view().viewers).toBe("");
  });

  test("ending the client leaves the page", () => {
    const t = onRoadmap();
    t.controller.dispose();
    expect(t.onPage.size).toBe(0);
  });
});

const deck = (id: string, title: string, fields: Record<string, unknown> = {}) =>
  [
    "deck",
    id,
    { id, spaceId: "s1", title, trashedAt: null, createdAt: at, updatedAt: at, ...fields },
  ] as const;
const slide = (id: string, title: string, order: string, body = "") =>
  ["slide", id, { id, deckId: "d1", title, body, order, createdAt: at, updatedAt: at }] as const;

describe("the presenter", () => {
  const presenting = (rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>) => {
    const t = inResearch([deck("d1", "Pitch"), ...rows]);
    t.select("deck:d1");
    t.controller.dispatch("space.present", {});
    return t;
  };

  test("a slide longer than the pane scrolls, and the next slide starts at its top", () => {
    const body = Array.from({ length: 60 }, (_, line) => `line ${line}`).join("\n");
    const t = presenting([slide("a", "Intro", "a", body), slide("b", "Plan", "b")]);
    expect(t.view().rows[0]!.text).toBe("Intro");
    t.controller.dispatch("space.pageDown", {});
    expect(t.view().title).toBe("present · Pitch · 1 / 2");
    expect(t.view().rows[0]!.text).not.toBe("Intro");
    t.controller.dispatch("space.next", {});
    expect(t.view().title).toBe("present · Pitch · 2 / 2");
    expect(t.view().rows[0]!.text).toBe("Plan");
  });

  test("keys that would edit do nothing while a slide is on show", () => {
    const t = presenting([slide("a", "Intro", "a")]);
    const before = t.calls.length;
    for (const action of ["space.delete", "space.new", "space.edit", "space.restore"]) {
      expect(t.controller.dispatch(action, {})).toBe(true);
    }
    expect(t.calls.length).toBe(before);
    expect(t.view().view).toBe("present");
  });

  test("Spaces close from the presenter", () => {
    const t = presenting([slide("a", "Intro", "a")]);
    t.controller.dispatch("space.close", {});
    expect(t.view().open).toBe(false);
  });

  test("a deck deleted for good stops the presenter and leaves the deck", () => {
    const t = presenting([slide("a", "Intro", "a")]);
    t.send("space:s1", events([11, "deck", "d1", { d: true }], [12, "slide", "a", { d: true }]));
    expect(t.view().view).toBe("pages");
  });
});

describe("editing a slide on one line", () => {
  /** Opens the slide's body field, its title left alone, and gives what the field shows. */
  const bodyField = (body: string) => {
    const t = inResearch([deck("d1", "Pitch"), slide("a", "Intro", "a", body)]);
    t.select("deck:d1");
    t.controller.dispatch("space.activate", {});
    t.select("slide:a");
    t.controller.dispatch("space.edit", {});
    t.asks.at(-1)!.onSubmit("Intro");
    const field = t.asks.at(-1)!;
    expect(field.label).toContain("slide body");
    const sent = () => t.calls.filter((call) => call.method === "space.slide.update");
    return { value: field.value!, submit: field.onSubmit, sent };
  };

  // Each is ambiguous to a field that writes a line break as " / ".
  const bodies = [
    "Either / or",
    "ends with /\nthen more",
    "first\n/ starts with",
    "/ /",
    "C:\\new\\table",
    "two\n\nparagraphs",
    "trailing line\n",
    "\\",
    "\\\n",
  ];

  test.each(bodies)("%j comes back as written after an edit", (body) => {
    const field = bodyField(body);
    expect(field.value).not.toContain("\n");
    field.submit(`${field.value}!`);
    expect(field.sent()).toEqual([
      {
        method: "space.slide.update",
        payload: { spaceId: "s1", slideId: "a", body: `${body}!` },
      },
    ]);
  });

  test.each([...bodies, "  outer spaces  "])("%j left as it was sends nothing", (body) => {
    const field = bodyField(body);
    field.submit(field.value.trim());
    expect(field.sent()).toEqual([]);
  });

  test("\\n typed in the field starts a new line, and any other backslash stays", () => {
    const field = bodyField("");
    field.submit("Up\\nDown \\o/");
    expect(field.sent().at(-1)?.payload).toMatchObject({ body: "Up\nDown \\o/" });
  });
});

describe("replies that come after the user moved on", () => {
  test("a new deck does not open once the user left the Space", async () => {
    const t = inResearch([page("p1", "Roadmap")]);
    t.select("page:p1");
    t.controller.dispatch("space.deckFromPage", {});
    t.controller.dispatch("space.back", {});
    t.reply("space.deck.createFromPage", { deck: deck("d1", "Roadmap")[2] });
    await t.controller.settled();
    expect(t.view().view).toBe("spaces");
  });

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

describe("a chart on a page", () => {
  const chart = (labels: number, series: number) => ({
    type: "bar",
    title: "Signups",
    source: "Numbers from this page",
    request: "signups by month",
    labels: Array.from({ length: labels }, (_, index) => `m${index}`),
    series: Array.from({ length: series }, (_, index) => ({
      name: `s${index}`,
      values: Array.from({ length: labels }, () => 1),
    })),
  });
  const chartBlock = (id: string, labels = 2, series = 1) => {
    const [kind, key, fields] = block(id, "p1", "Signups (a chart; Numbers from this page)", "b");
    return [kind, key, { ...fields, kind: "chart", chart: chart(labels, series) }] as const;
  };
  const onPage = (...rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>) => {
    const t = inResearch([page("p1", "Status"), ...rows]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    return t;
  };

  test("draws its title, its numbers and where they came from", () => {
    const t = onPage(chartBlock("c1"));
    const rows = t.view().rows.filter((row) => row.blockKind === "chart");
    expect(rows.map((row) => row.key)).toEqual(Array(4).fill("block:c1"));
    expect(rows[0]!.text).toContain("Signups");
    expect(rows[1]!.text).toEndWith(" 1");
    expect(rows.at(-1)!.text.trim()).toBe("Numbers from this page");
    expect(rows.filter((row) => row.first)).toHaveLength(1);
  });

  test("shows its own words when the description cannot be read", () => {
    const [kind, key, fields] = chartBlock("c1");
    const t = onPage([kind, key, { ...fields, chart: "not a chart" }]);
    expect(t.texts("block")).toEqual(["Signups (a chart; Numbers from this page)"]);
  });

  test("shows its own words when its numbers do not match its labels", () => {
    const [kind, key, fields] = chartBlock("c1");
    const chart = { ...fields.chart, series: [{ name: "Signups", values: [3] }] };
    const t = onPage([kind, key, { ...fields, chart }]);
    expect(t.texts("block")).toEqual(["Signups (a chart; Numbers from this page)"]);
  });

  test("asks again from the words it was asked for in, and replaces itself", async () => {
    const t = onPage(chartBlock("c1"));
    t.select("block:c1");
    t.controller.dispatch("space.activate", {});
    const asked = t.asks.at(-1)!;
    expect(asked.value).toBe("signups by month");
    asked.onSubmit("signups by week");
    expect(t.statuses.at(-1)).toBe("Drawing a chart…");
    expect(t.calls.at(-1)).toEqual({
      method: "space.block.visualize",
      payload: { spaceId: "s1", pageId: "p1", request: "signups by week", blockId: "c1" },
    });
    t.reply("space.block.visualize", { block: chartBlock("c1")[2] });
    await t.controller.settled();
    expect(t.statuses.at(-1)).toBe("Drew “Signups”.");
  });

  test("a new chart goes after the selected block", () => {
    const t = onPage(block("b1", "p1", "Before", "a"));
    t.select("block:b1");
    t.controller.dispatch("space.visualize", {});
    expect(t.asks.at(-1)!.value).toBeUndefined();
    t.asks.at(-1)!.onSubmit("signups");
    expect(t.calls.at(-1)!.payload).toEqual({
      spaceId: "s1",
      pageId: "p1",
      request: "signups",
      afterBlockId: "b1",
    });
  });

  test("a chart from the add menu is a new one, even with a chart selected", () => {
    const t = onPage(chartBlock("c1"));
    t.select("block:c1");
    t.controller.dispatch("space.new", {});
    t.menus.at(-1)!.onChoose("chart");
    expect(t.asks.at(-1)!.value).toBeUndefined();
    t.asks.at(-1)!.onSubmit("signups");
    expect(t.calls.at(-1)!.payload).toEqual({
      spaceId: "s1",
      pageId: "p1",
      request: "signups",
      afterBlockId: "c1",
    });
  });

  test("off a page there is nothing to chart on", () => {
    const t = inResearch([page("p1", "Status")]);
    t.controller.dispatch("space.visualize", {});
    expect(t.asks).toEqual([]);
    expect(t.statuses.at(-1)).toBe("Open a page to ask for a chart.");
  });

  test("scrolls through itself when it is taller than the pane, then moves on", () => {
    const t = onPage(chartBlock("c1", 24, 4), block("b1", "p1", "After", "c"));
    t.select("block:c1");
    const top = () => t.view().rows[0]!.text;
    const before = top();
    t.controller.dispatch("space.next", {});
    expect(top()).not.toBe(before);
    expect(t.view().rows.some((row) => row.selected && row.key === "block:c1")).toBe(true);
    for (let step = 0; step < 100; step += 1) t.controller.dispatch("space.next", {});
    expect(t.view().rows.some((row) => row.selected && row.key === "block:b1")).toBe(true);
  });
});

describe("Markdown a page keeps as written", () => {
  const raw = (id: string, text: string) => {
    const [kind, key, fields] = block(id, "p1", text, "b");
    return [kind, key, { ...fields, kind: "raw" }] as const;
  };
  const onPage = (...rows: ReadonlyArray<readonly [string, string, Record<string, unknown>]>) => {
    const t = inResearch([page("p1", "Plan"), ...rows]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    return t;
  };
  /** The source as the rows show it, after the marker and the gutter. */
  const shown = (t: ReturnType<typeof onPage>) =>
    t
      .view()
      .rows.filter((row) => row.blockKind === "raw")
      .map((row) => row.text.slice(4));

  test("is a row per line, its spaces and blank lines kept and its tabs at stops of four", () => {
    const t = onPage(raw("r1", "  - nested\n\n```sh\n\tmake\na\tb\n```"));
    expect(shown(t)).toEqual(["  - nested", "", "```sh", "    make", "a   b", "```"]);
    expect(t.view().rows.filter((row) => row.blockKind === "raw" && row.first)).toHaveLength(1);
  });

  test("a line wider than the pane is cut short, never wrapped", () => {
    const t = onPage(raw("r1", `| ${"cell | ".repeat(20)}`));
    const rows = shown(t);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toEndWith("…");
  });

  test("is edited on one line, sent as typed with its spaces", () => {
    const t = onPage(raw("r1", "  | a |\n  | - |"));
    t.select("block:r1");
    t.controller.dispatch("space.edit", {});
    const field = t.asks.at(-1)!;
    expect(field).toMatchObject({ value: "  | a |\\n  | - |", untrimmed: true });
    const sent = () => t.calls.filter((call) => call.method === "space.block.update");
    field.onSubmit(field.value!);
    expect(sent()).toEqual([]);
    field.onSubmit(`${field.value}\\n  | b |`);
    expect(sent().at(-1)?.payload).toEqual({
      spaceId: "s1",
      blockId: "r1",
      text: "  | a |\n  | - |\n  | b |",
    });
  });
});

describe("a heading", () => {
  const heading = (id: string, text: string, order: string, level?: number) => {
    const [kind, key, fields] = block(id, "p1", text, order);
    return [kind, key, { ...fields, kind: "heading", ...(level ? { level } : {}) }] as const;
  };

  test("carries its level's marks, a second level when it has none", () => {
    const t = inResearch([
      page("p1", "Plan"),
      heading("h1", "Top", "a", 1),
      heading("h2", "Steps", "b"),
      heading("h6", "Fine print", "c", 6),
    ]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    expect(t.texts("block")).toEqual(["# Top", "## Steps", "###### Fine print"]);
  });
});

describe("publishing a page as a site", () => {
  const publishPayload = (origin: string, action = "space.publish") => {
    const t = inResearch([page("p1", "Roadmap")], origin);
    t.select("page:p1");
    t.controller.dispatch(action, {});
    return t.calls.find((call) => call.method === "space.page.publish")?.payload;
  };

  test("a client that reached the MC on the LAN makes the link on that address", () => {
    expect(publishPayload("http://192.168.1.20:3773")).toEqual({
      spaceId: "s1",
      pageId: "p1",
      baseUrl: "http://192.168.1.20:3773",
    });
  });

  test("a client on loopback leaves the address to the MC", () => {
    expect(publishPayload("http://127.0.0.1:3773")).toEqual({ spaceId: "s1", pageId: "p1" });
  });

  test("over Tailscale the MC names the address, wherever the client reached it", () => {
    expect(publishPayload("http://192.168.1.20:3773", "space.publishTailscale")).toEqual({
      spaceId: "s1",
      pageId: "p1",
      tailscale: true,
    });
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
    expect(t.statuses).toEqual(["No agent was asked on this page: A asks one."]);
  });

  test("an error that ends its own sentence is not given a second full stop", () => {
    const failed = onRoadmap(agent({ status: "failed", error: "The agent's turn failed." }));
    expect(failed.view().message).toStartWith(
      "The agent failed: The agent's turn failed. The page stays as it last wrote it.",
    );
    const stopped = onRoadmap(agent({ status: "stopped", error: "It was cut off.\n" }));
    expect(stopped.view().message).toStartWith("The agent stopped: It was cut off. ·");
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

  test("a page down under a wrapped message steps by the rows on show", () => {
    const blocks = Array.from({ length: 40 }, (_, index) =>
      block(`b${index}`, "p1", `Block ${index}`, `a${String(index).padStart(2, "0")}`),
    );
    const t = onRoadmap(...blocks, agent({ request: "tidy ".repeat(100) }));
    const selected = () =>
      t
        .view()
        .rows.find((row) => row.selected)!
        .text.slice(2)
        .trim();
    t.select("block:b0");
    const onShow = t.view().rows.length;
    t.controller.dispatch("space.pageDown", {});
    expect(selected()).toBe(`Block ${onShow}`);
  });

  test("an entry taller than the pane under a wrapped message scrolls a row at a time to its end", () => {
    const tall = `${Array.from({ length: 800 }, (_, index) => `w${index}`).join(" ")} end`;
    const t = onRoadmap(
      block("b0", "p1", tall, "a0"),
      block("b1", "p1", "After", "a1"),
      agent({ request: "tidy ".repeat(100) }),
    );
    t.select("block:b0");
    const shown = () => t.view().rows.map((row) => row.text);
    let before = shown();
    for (let step = 0; step < 200 && !before.some((text) => text.endsWith(" end")); step += 1) {
      t.controller.dispatch("space.next", {});
      const after = shown();
      expect(after[0]).toBe(before[1]);
      before = after;
    }
    expect(before.some((text) => text.endsWith(" end"))).toBe(true);
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

describe("a page's prompt", () => {
  const onRoadmap = () => {
    const t = inResearch([page("p1", "Roadmap")]);
    t.select("page:p1");
    t.controller.dispatch("space.activate", {});
    return t;
  };
  const words = (text: string, attachments: ReadonlyArray<never> = []) => ({
    text,
    attachments,
    projectId: "p1",
    modelSelection: null,
    runtimeMode: "full-access" as const,
    interactionMode: "default" as const,
  });
  const sent = (t: ReturnType<typeof setup>, method: string) =>
    t.calls.filter((call) => call.method === method).map((call) => call.payload);

  test("aims at the open page, and ^P moves the keys to it and back", async () => {
    const t = onRoadmap();
    await t.controller.settled();
    expect(t.controller.prompt()).toMatchObject({
      key: "page:s1:p1",
      title: "Roadmap",
      writes: "writes a paragraph",
      defaultProjectId: "p1",
    });
    expect(t.controller.mode()).toBe("space");
    t.controller.dispatch("space.prompt", {});
    expect(t.controller.mode()).toBe("pagePrompt");
    t.controller.dispatch("space.focus", {});
    expect(t.controller.mode()).toBe("space");
    t.controller.dispatch("space.back", {});
    expect(t.controller.prompt()).toBeNull();
  });

  test("plain words write a block of the kind / chose, and a heading is one block", async () => {
    const t = onRoadmap();
    const prompt = t.controller.prompt()!;
    expect(prompt.kinds.map((kind) => kind.label)).toContain("Visualize");
    expect(prompt.kinds.map((kind) => kind.label)).not.toContain("Chart");
    expect(prompt.chooseKind("heading")).toBe("");
    expect(t.controller.prompt()!.writes).toBe("writes a heading");
    const written = t.controller.prompt()!.submit(words("Plans"));
    t.reply("space.block.insert", { block: block("b1", "p1", "Plans", "a0")[2] });
    expect(await written).toBeNull();
    expect(sent(t, "space.block.insert")).toEqual([
      { spaceId: "s1", pageId: "p1", kind: "heading", text: "Plans" },
    ]);
    expect(t.controller.prompt()!.writes).toBe("writes a paragraph");
    expect(prompt.chooseKind("chart")).toBe("/visualize ");
  });

  test("@agent asks with the prompt's choices, and a refusal comes back as words", async () => {
    const t = onRoadmap();
    const asked = t.controller.prompt()!.submit(words("@agent tidy this"));
    t.refuse("space.page.askAgent", new Error("That model cannot run here."));
    expect(await asked).toBe("That model cannot run here.");
    expect(sent(t, "space.page.askAgent")).toEqual([
      {
        spaceId: "s1",
        pageId: "p1",
        request: "tidy this",
        projectId: "p1",
        runtimeMode: "full-access",
        interactionMode: "default",
      },
    ]);
  });

  test("images go only with an ask", async () => {
    const t = onRoadmap();
    const upload = { type: "image", name: "a.png" } as never;
    expect(await t.controller.prompt()!.submit(words("Plans", [upload]))).toBe(
      "Images go with an ask: start the prompt with @agent.",
    );
  });

  test("/visualize lets go of the prompt while the chart is drawn, and says why one was not", async () => {
    const t = onRoadmap();
    // The prompt is free before the MC answers: a model draws the chart.
    expect(await t.controller.prompt()!.submit(words("/visualize sales by month"))).toBeNull();
    expect(sent(t, "space.block.visualize")).toEqual([
      { spaceId: "s1", pageId: "p1", request: "sales by month" },
    ]);
    expect(t.statuses.at(-1)).toBe("Drawing a chart…");
    t.refuse("space.block.visualize", new Error("No numbers to chart."));
    await t.controller.settled();
    expect(t.statuses.at(-1)).toBe("No numbers to chart.");
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

  test("an image by its address is its caption and where it is, never fetched", () => {
    const byAddress = (id: string, text: string) =>
      [
        "block",
        id,
        { ...block(id, "p1", text, id)[2], kind: "image", url: "https://x.test/a.png" },
      ] as const;
    const t = onPage([byAddress("a", "A cat"), byAddress("b", "")]);
    expect(t.texts("block")).toEqual([
      "[image: A cat] https://x.test/a.png",
      "[image] https://x.test/a.png",
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
    t.asks.at(-1)!.onSubmit("/home/me/cat.png");
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

describe("project files", () => {
  test("a file opens as a page of its project's Space, with no Space of the user's", async () => {
    const t = setup();
    t.controller.dispatch("space.openProjectFile", { projectId: "p1", path: "docs/guide.md" });
    t.reply("space.page.openFile", { spaceId: "ps1", page: page("g1", "Guide")[2], created: true });
    await t.controller.settled();
    // The pane it shows asks for its Spaces afterwards; nothing is asked before the file.
    expect(t.calls[0]).toEqual({
      method: "space.page.openFile",
      payload: { projectId: "p1", relativePath: "docs/guide.md" },
    });
    expect(t.statuses.at(-1)).toBe("Opened docs/guide.md as the page “Guide”.");
  });

  test("the project's Space stays open once the Spaces arrive without it", async () => {
    const t = setup();
    t.controller.dispatch("space.openProjectFile", { projectId: "p1", path: "docs/guide.md" });
    t.reply("space.page.openFile", { spaceId: "ps1", page: page("g1", "Guide")[2], created: true });
    await t.controller.settled();
    const shop = { id: "ps1", projectId: "p1", name: "shop", createdAt: at, updatedAt: at };
    t.send("spaces", snapshot(1, [space("s1", "Research"), ["projectSpace", "ps1", shop]]));
    t.send("space:ps1", snapshot(10, [page("g1", "Guide")]));
    expect(t.statuses).not.toContain("The Space was deleted.");
    expect(t.view().title).toBe("page · Guide");
    t.controller.dispatch("space.back", {});
    expect(t.view().title).toBe("space · shop");
  });

  test("a file opened again is the page it already is", async () => {
    const t = setup();
    t.controller.dispatch("space.openProjectFile", { projectId: "p1", path: "docs/guide.md" });
    t.reply("space.page.openFile", {
      spaceId: "ps1",
      page: page("g1", "Guide")[2],
      created: false,
    });
    await t.controller.settled();
    expect(t.statuses.at(-1)).toBe("docs/guide.md is the page “Guide”.");
  });

  test("a project of another machine is not asked of this MC", async () => {
    const t = setup();
    t.controller.dispatch("space.openProjectFile", { projectId: "env2:p9", paths: ["a.md"] });
    await t.controller.settled();
    expect(t.statuses.at(-1)).toStartWith("That project is on another machine");
    expect(t.calls).toEqual([]);
  });

  test("a list the MC failed to give is asked for again", async () => {
    const t = setup();
    t.projectFiles.byHand = true;
    expect(t.controller.isSpaceFile("p1", "docs/guide.md")).toBe(false);
    t.refuse("space.files.list", new Error("lost the connection"));
    await t.controller.settled();
    expect(t.controller.isSpaceFile("p1", "docs/guide.md")).toBe(false);
    t.reply("space.files.list", {
      config: "default",
      files: [{ relativePath: "docs/guide.md", kind: "page", page: null }],
    });
    await t.controller.settled();
    expect(t.controller.isSpaceFile("p1", "docs/guide.md")).toBe(true);
    expect(t.calls.filter((call) => call.method === "space.files.list")).toHaveLength(2);
  });
});

describe("projects in the Space's pages", () => {
  const guide = page("g1", "Guide", {
    spaceId: "ps1",
    file: { projectId: "p1", path: "docs/guide.md", missing: false, conflictAt: null },
  });
  const shop = { id: "ps1", projectId: "p1", name: "shop", createdAt: at, updatedAt: at };

  /** In Research, with shop's Space files listed. */
  async function withShop(paths: string[], sections = memoryMutedThreads()) {
    const t = inResearch([page("p1", "Plan")], undefined, { projectSections: sections });
    t.projectFiles.paths = paths;
    t.controller.dispatch("space.close", {});
    t.controller.dispatch("space.open", {});
    await t.controller.settled();
    t.send("spaces", snapshot(2, [space("s1", "Research"), ["projectSpace", "ps1", shop]]));
    t.select("space:s1");
    t.controller.dispatch("space.activate", {});
    t.send("space:s1", snapshot(10, [page("p1", "Plan")]), -1);
    return t;
  }

  test("a project shows after the Space's pages, collapsed, and expands to its files by folder", async () => {
    const t = await withShop(["docs/guide.md", "README.md"]);
    expect(t.view().rows.map((row) => row.key)).toEqual(["page:p1", "project:p1"]);
    expect(t.texts("project")).toEqual(["▸ shop"]);
    t.select("project:p1");
    t.controller.dispatch("space.activate", {});
    const drawn = () =>
      t
        .view()
        .rows.slice(1)
        .map((row) => row.text.trim());
    // A folder starts collapsed too.
    expect(drawn()).toEqual(["▸ ▾ shop", "▸ docs/", "README.md"]);
    t.select("folder:p1|docs");
    t.controller.dispatch("space.activate", {});
    expect(drawn()).toEqual(["▾ shop", "▸ ▾ docs/", "guide.md", "README.md"]);
    t.controller.dispatch("space.activate", {});
    expect(t.texts("file")).toEqual(["README.md"]);
    t.select("project:p1");
    t.controller.dispatch("space.activate", {});
    expect(t.texts("file")).toEqual([]);
  });

  test("a project with no Space files has no section", async () => {
    const t = await withShop([]);
    expect(t.texts("project")).toEqual([]);
  });

  test("the expanded sections are remembered for the next start", async () => {
    const sections = memoryMutedThreads();
    // A project removed since is forgotten with the next change, its folders with it.
    sections.save(["gone", "gone|docs"]);
    const t = await withShop(["docs/guide.md"], sections);
    t.select("project:p1");
    t.controller.dispatch("space.activate", {});
    expect(sections.load()).toEqual(["p1"]);
    t.select("folder:p1|docs");
    t.controller.dispatch("space.activate", {});
    expect(sections.load()).toEqual(["p1", "p1|docs"]);
    const again = await withShop(["docs/guide.md"], sections);
    expect(again.texts("project")).toEqual(["▾ shop"]);
    expect(again.texts("file")).toEqual(["guide.md"]);
  });

  test("a remembered folder the project's files are no longer in is forgotten", async () => {
    const sections = memoryMutedThreads();
    sections.save(["p1", "p1|docs", "p1|notes", "p1|docs/api"]);
    const t = await withShop(["docs/guide.md", "README.md"], sections);
    expect(sections.load()).toEqual(["p1", "p1|docs"]);
    expect(t.texts("file")).toEqual(["guide.md", "README.md"]);
  });

  test("a file picked in its section opens from the project's Space, and back is the Space it was picked in", async () => {
    const t = await withShop(["docs/guide.md"]);
    t.select("project:p1");
    t.controller.dispatch("space.activate", {});
    t.select("folder:p1|docs");
    t.controller.dispatch("space.activate", {});
    t.select("file:p1|docs/guide.md");
    t.controller.dispatch("space.activate", {});
    t.reply("space.page.openFile", { spaceId: "ps1", page: guide[2], created: false });
    await t.controller.settled();
    t.send("space:ps1", snapshot(10, [guide]));
    expect(t.view().title).toBe("page · Guide");
    t.controller.dispatch("space.back", {});
    expect(t.view().title).toBe("space · Research");
    expect(t.view().rows.find((row) => row.selected)?.key).toBe("file:p1|docs/guide.md");
  });

  test("a file opened from elsewhere expands its section and folders, and its page goes back to a Space of the user's", async () => {
    const sections = memoryMutedThreads();
    const t = setup(undefined, { projectSections: sections });
    t.projectFiles.paths = ["docs/guide.md"];
    t.controller.dispatch("space.openProjectFile", { projectId: "p1", path: "docs/guide.md" });
    t.reply("space.page.openFile", { spaceId: "ps1", page: guide[2], created: true });
    await t.controller.settled();
    t.send("spaces", snapshot(1, [space("s1", "Research"), ["projectSpace", "ps1", shop]]));
    t.send("space:ps1", snapshot(10, [guide]));
    expect(sections.load()).toEqual(["p1", "p1|docs"]);
    t.controller.dispatch("space.back", {});
    expect(t.view().title).toBe("space · Research");
    expect(t.view().rows.find((row) => row.selected)?.key).toBe("file:p1|docs/guide.md");
  });

  test("a file's page deleted for good goes back to the user's Space, not the project's", async () => {
    const t = await withShop(["docs/guide.md"]);
    t.controller.dispatch("space.openProjectFile", { projectId: "p1", path: "docs/guide.md" });
    t.reply("space.page.openFile", { spaceId: "ps1", page: guide[2], created: false });
    await t.controller.settled();
    t.send("space:ps1", snapshot(10, [guide]));
    t.send("space:ps1", snapshot(11, []));
    expect(t.view().title).toBe("space · Research");
  });
});

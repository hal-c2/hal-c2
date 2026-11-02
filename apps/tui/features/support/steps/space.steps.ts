// space/pages.feature and space/slides.feature: the Spaces pane (^X p), driven by its keys against a fake
// MC that keeps the rules of HalC2.Space (fakeSpaceMc.ts). Givens write to the MC
// directly; Whens press the pane's keys and answer its fields and pickers; Thens
// read what the pane shows, the status line and the clipboard. A second client is
// a second host on the same MC, following the same streams.
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import { type SpaceAuthor, ThreadId } from "@hal-c2/contracts";

import { createHost, type Host } from "../../../src/host/host.ts";
import type { TuiSelectState } from "../../../src/host/composerState.ts";
import {
  SITE_BEHIND_HINT,
  SITE_LOCAL_ONLY_HINT,
  type TuiSpaceRow,
  type TuiSpaceState,
} from "../../../src/host/spaceState.ts";
import { step } from "../../steps.ts";
import { env, projectNamed, threadNamed, ui } from "../environment.ts";
import { fakeClient } from "../fakeClient.ts";
import { fakeSpaceMc, type FakeSpaceMc } from "../fakeSpaceMc.ts";
import { findObject, pressKey, settle, typeText, type World } from "../world.ts";

interface SpaceWorld extends World {
  /** The site link each page had when the scenario first saw it. */
  siteLinks?: Map<string, string>;
  spaceMc?: FakeSpaceMc;
  /** The Space the scenario's pages are in: the newest one a Given named. */
  spaceName?: string;
  /** Page ids by title, kept so a Then can name pages deleted for good. */
  pageIds?: Map<string, string>;
  second?: Host;
  /** The page whose history the scenario last opened. */
  historyPage?: string;
}

const SUMMARY_TITLE = "Release plan";
const SUMMARY = `# ${SUMMARY_TITLE}

## Goals

Ship pages in July.

- [ ] Cut the branch
- [ ] Write the notes
`;
const UNAVAILABLE = "No text generation provider is set up.";
const FAILED = "The provider returned no text.";

// --- the MC ---

function mc(ctx: SpaceWorld): FakeSpaceMc {
  ctx.spaceMc ??= fakeSpaceMc({
    cwdOf: (threadId) => {
      const thread = env(ctx).threads.find((candidate) => candidate.id === threadId);
      if (!thread) return null;
      const project = env(ctx).projects.find((candidate) => candidate.id === thread.projectId);
      return thread.worktreePath ?? project?.workspaceRoot ?? null;
    },
    titleOf: (threadId) =>
      env(ctx).threads.find((candidate) => candidate.id === threadId)?.title ?? null,
  });
  return ctx.spaceMc;
}

const agent = (ctx: SpaceWorld, thread: string): SpaceAuthor => ({
  type: "agent",
  threadId: ThreadId.make(threadNamed(ctx, thread).id),
});

function seedSpace(ctx: SpaceWorld, name: string) {
  mc(ctx).run("space.list", {});
  const found = mc(ctx)
    .spaces()
    .find((entry) => entry.name === name);
  const id = found ? found.id : mc(ctx).run("space.create", { name }).space.id;
  ctx.spaceName = name;
  return id as string;
}

const currentSpaceId = (ctx: SpaceWorld) => mc(ctx).spaceNamed(ctx.spaceName!).id as string;
const pageId = (ctx: SpaceWorld, title: string) => mc(ctx).pageNamed(title).id as string;

function seedPage(ctx: SpaceWorld, title: string, parent?: string) {
  const existing = mc(ctx)
    .pagesOf(currentSpaceId(ctx))
    .find((page) => page.title === title);
  if (existing) return existing.id as string;
  const { page } = mc(ctx).run("space.page.create", {
    spaceId: currentSpaceId(ctx),
    title,
    ...(parent ? { parentPageId: seedPage(ctx, parent) } : {}),
  });
  (ctx.pageIds ??= new Map()).set(title, page.id);
  return page.id as string;
}

function seedBlock(ctx: SpaceWorld, page: string, kind: string, text: string, checked = false) {
  const { block } = mc(ctx).run("space.block.insert", {
    spaceId: currentSpaceId(ctx),
    pageId: seedPage(ctx, page),
    kind,
    text,
  });
  if (checked) {
    mc(ctx).run("space.block.setChecked", {
      spaceId: currentSpaceId(ctx),
      blockId: block.id,
      checked: true,
    });
  }
}

// --- the pane ---

const pane = (ctx: World) => ctx.host!.state.get("space") as TuiSpaceState;
const mode = (ctx: World) => ctx.host!.state.get("mode") as string;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };

/** A row's words, without the selection marker and the indent. */
const words = (row: TuiSpaceRow) => row.text.slice(2).trim();

/** The client runs, connected, its Spaces served by the MC. */
async function start(ctx: SpaceWorld) {
  await ui(ctx);
  if (ctx.fake!.settings.streams === null) mc(ctx).attach(ctx.fake!.settings);
}

async function openSpaces(ctx: SpaceWorld) {
  await start(ctx);
  if (!pane(ctx).open) {
    await pressKey(ctx, "Ctrl+X");
    await pressKey(ctx, "p");
    await settle(ctx);
  }
  expect(pane(ctx).open).toBe(true);
  while (pane(ctx).view !== "spaces") await pressKey(ctx, "Esc");
  await settle(ctx);
}

/** Move the selection to the entry `key` with j and k. */
async function selectRow(ctx: World, key: string) {
  const selectedKey = () => pane(ctx).rows.find((row) => row.selected)?.key;
  for (let presses = 0; presses < 100 && selectedKey() !== key; presses += 1) {
    const rows = pane(ctx).rows;
    const target = rows.findIndex((row) => row.key === key);
    const at = rows.findIndex((row) => row.selected);
    await pressKey(ctx, target >= 0 && target < at ? "k" : "j");
  }
  expect(selectedKey()).toBe(key);
}

async function openSpace(ctx: SpaceWorld, name = ctx.spaceName!) {
  await openSpaces(ctx);
  await selectRow(ctx, `space:${mc(ctx).spaceNamed(name).id}`);
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(pane(ctx).view).toBe("pages");
}

/** The page's row in the tree: in the trash or out of it. */
const treeKey = (ctx: SpaceWorld, title: string) => {
  const page = mc(ctx).pageNamed(title);
  return pane(ctx).rows.some((row) => row.key === `trash:${page.id}`)
    ? `trash:${page.id}`
    : `page:${page.id}`;
};

async function openPage(ctx: SpaceWorld, title: string) {
  await start(ctx);
  const page = mc(ctx).pageNamed(title);
  const view = pane(ctx);
  if (view.open && view.view === "page" && view.title.startsWith(`page · ${title}`)) return;
  await openSpace(
    ctx,
    mc(ctx)
      .spaces()
      .find((entry) => entry.id === page.spaceId)!.name,
  );
  await selectRow(ctx, treeKey(ctx, title));
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(pane(ctx).view).toBe("page");
}

async function selectPage(ctx: SpaceWorld, title: string) {
  await openSpace(ctx);
  await selectRow(ctx, treeKey(ctx, title));
}

const blockKey = (ctx: SpaceWorld, text: string) => `block:${mc(ctx).blockNamed(text).id}`;
const commentKey = (ctx: SpaceWorld, body: string) => `comment:${mc(ctx).commentNamed(body).id}`;

/** Answer the field the pane asked with, replacing what it held. */
async function answer(ctx: World, text: string) {
  expect(mode(ctx)).toBe("ask");
  findObject(ctx, "askInput").set("text", "");
  if (text !== "") await typeText(ctx, text);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

/** Pick the option `label` in the open picker. */
async function choose(ctx: World, label: string) {
  expect(mode(ctx)).toBe("select");
  const index = select(ctx).options.findIndex((option) => option.label === label);
  expect(index).toBeGreaterThanOrEqual(0);
  while (select(ctx).index < index) await pressKey(ctx, "Down");
  while (select(ctx).index > index) await pressKey(ctx, "Up");
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

async function press(ctx: World, key: string) {
  await pressKey(ctx, key);
  await settle(ctx);
}

const listed = (rows: ReadonlyArray<TuiSpaceRow>, kind: TuiSpaceRow["kind"]) =>
  rows.filter((row) => row.kind === kind && row.first).map(words);

const list = (text: string) => (text === "" ? [] : text.split(", "));

/** The rows of a page's blocks, each block once. */
async function blockRows(ctx: SpaceWorld, title: string) {
  await openPage(ctx, title);
  return pane(ctx).rows.filter((row) => row.kind === "block" && row.first);
}

/** A block's words, after its tick box, bar or arrow and before the agent that wrote it. */
const blockText = (row: TuiSpaceRow) =>
  words(row)
    .replace(/^(\[[ x]\] |▌ |↳ )/, "")
    .replace(/ {2}· .*$/, "");

// --- Spaces ---

step("a connected environment", (ctx: SpaceWorld) => {
  env(ctx);
});

step("the user lists their Spaces", openSpaces);

step("the user has listed their Spaces", (ctx: SpaceWorld) => {
  mc(ctx).run("space.list", {});
});

step("the Spaces are {string}", async (ctx: SpaceWorld, names: string) => {
  await openSpaces(ctx);
  expect(listed(pane(ctx).rows, "space")).toEqual(list(names));
});

step("the user makes the Space {string}", async (ctx: SpaceWorld, name: string) => {
  await openSpaces(ctx);
  await press(ctx, "n");
  await answer(ctx, name);
});

step("the Space {string}", (ctx: SpaceWorld, name: string) => {
  seedSpace(ctx, name);
});

step(
  "the user renames the Space {string} to {string}",
  async (ctx: SpaceWorld, from: string, to: string) => {
    await openSpaces(ctx);
    await selectRow(ctx, `space:${mc(ctx).spaceNamed(from).id}`);
    await press(ctx, "e");
    await answer(ctx, to);
  },
);

step("the user deletes the Space {string}", async (ctx: SpaceWorld, name: string) => {
  await openSpaces(ctx);
  await selectRow(ctx, `space:${mc(ctx).spaceNamed(name).id}`);
  await press(ctx, "d");
});

// The pane says why, in the MC's words.
const refused = async (ctx: SpaceWorld) => {
  await settle(ctx);
  const reason = mc(ctx).refusals.at(-1);
  expect(reason).toBeDefined();
  expect(status(ctx)).toEqual(expect.objectContaining({ text: reason, kind: "error" }));
};

step("the Space request is refused", refused);
step("the page request is refused", refused);
step("the deck request is refused", refused);

// The pane knows a block has no box, and says so without asking the MC.
step("the user is told only a checklist item can be ticked", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(mc(ctx).refusals).toEqual([]);
  expect(status(ctx)).toEqual(
    expect.objectContaining({ text: "Only a checklist item can be ticked.", kind: "info" }),
  );
});

step("the Space {string} with the page {string}", (ctx: SpaceWorld, name: string, page) => {
  seedSpace(ctx, name);
  seedPage(ctx, page);
});

// --- a second client ---

async function secondClient(ctx: SpaceWorld): Promise<Host> {
  await start(ctx);
  const fake = fakeClient();
  mc(ctx).attach(fake.settings);
  const host = createHost({
    client: fake.client,
    size: { columns: 100, rows: 40 },
    log: () => {},
    onQuit: () => {},
  });
  ctx.cleanups.push(() => host.destroy());
  await host.ready;
  fake.connect();
  host.dispatch("space.open");
  await host.settled();
  ctx.second = host;
  return host;
}

const secondPane = (ctx: SpaceWorld) => ctx.second!.state.get("space") as TuiSpaceState;

step("a second client watching the Spaces", async (ctx: SpaceWorld) => {
  await secondClient(ctx);
});

step("the second client sees the Space {string}", async (ctx: SpaceWorld, name: string) => {
  await ctx.second!.settled();
  expect(listed(secondPane(ctx).rows, "space")).toContain(name);
});

// It reads the Space's first entry, where the edit lands: a page, or a deck if that comes first.
step("a second client watching the Space {string}", async (ctx: SpaceWorld, name: string) => {
  const host = await secondClient(ctx);
  host.dispatch("space.select", { key: `space:${mc(ctx).spaceNamed(name).id}` });
  host.dispatch("space.activate");
  host.dispatch("space.activate");
  await host.settled();
  expect(secondPane(ctx).view).not.toBe("spaces");
});

step("the second client sees the block {string}", async (ctx: SpaceWorld, text: string) => {
  await ctx.second!.settled();
  const rows = secondPane(ctx).rows.filter((row) => row.kind === "block" && row.first);
  expect(rows.map(blockText)).toContain(text);
});

// --- pages and their places ---

step("the user makes the page {string}", async (ctx: SpaceWorld, title: string) => {
  await openSpace(ctx);
  await press(ctx, "n");
  await answer(ctx, title);
});

step("the pages of {string} are {string}", async (ctx: SpaceWorld, name: string, titles) => {
  await openSpace(ctx, name);
  expect(listed(pane(ctx).rows, "page")).toEqual(list(titles));
});

step("the page {string}", (ctx: SpaceWorld, title: string) => {
  seedPage(ctx, title);
});

step(
  "the user makes the page {string} inside {string}",
  async (ctx: SpaceWorld, title: string, parent: string) => {
    await selectPage(ctx, parent);
    await press(ctx, "a");
    await answer(ctx, title);
  },
);

/** The tree shows `title` one level below the row above it at `parent`'s depth. */
async function expectPlace(ctx: SpaceWorld, title: string, parent: string | null) {
  await openSpace(ctx);
  const page = mc(ctx).pageNamed(title);
  expect(page.parentPageId).toBe(parent === null ? null : pageId(ctx, parent));
  const rows = pane(ctx).rows.filter((row) => row.kind === "page");
  const at = rows.findIndex((row) => row.key === `page:${page.id}`);
  expect(at).toBeGreaterThanOrEqual(0);
  if (parent === null) {
    expect(rows[at]!.depth).toBe(0);
    return;
  }
  const above = rows.findIndex((row) => row.key === `page:${pageId(ctx, parent)}`);
  expect(above).toBeGreaterThanOrEqual(0);
  expect(above).toBeLessThan(at);
  expect(rows[at]!.depth).toBe(rows[above]!.depth! + 1);
}

step("{string} is a subpage of {string}", (ctx: SpaceWorld, title: string, parent: string) =>
  expectPlace(ctx, title, parent),
);

step("{string} is not inside another page", (ctx: SpaceWorld, title: string) =>
  expectPlace(ctx, title, null),
);

step(
  "the user renames the page {string} to {string}",
  async (ctx: SpaceWorld, from: string, to: string) => {
    await selectPage(ctx, from);
    await press(ctx, "e");
    await answer(ctx, to);
  },
);

step("the page {string} inside {string}", (ctx: SpaceWorld, title: string, parent: string) => {
  seedPage(ctx, title, parent);
});

step(
  "the user moves the page {string} to the top of the Space",
  async (ctx: SpaceWorld, title: string) => {
    await selectPage(ctx, title);
    await press(ctx, "m");
    await choose(ctx, "The top of the Space");
  },
);

step("the pages {string} and {string}", (ctx: SpaceWorld, a: string, b: string) => {
  seedPage(ctx, a);
  seedPage(ctx, b);
});

step(
  "the user moves the page {string} into {string}",
  async (ctx: SpaceWorld, title: string, parent: string) => {
    await selectPage(ctx, title);
    await press(ctx, "m");
    await choose(ctx, parent);
  },
);

step("the page {string} reads {string}", (ctx: SpaceWorld, title: string, text: string) => {
  seedBlock(ctx, title, "paragraph", text);
});

// The client was reading the page: it takes the MC's fresh snapshot in place of what it held.
step("the MC restarts", async (ctx: SpaceWorld) => {
  const first = mc(ctx).pagesOf(currentSpaceId(ctx))[0];
  if (first) await openPage(ctx, first.title);
  mc(ctx).restart();
  await settle(ctx);
});

step("the page {string} still reads {string}", async (ctx: SpaceWorld, title: string, text) => {
  expect((await blockRows(ctx, title)).map(blockText)).toEqual([text]);
});

// --- trash ---

step("the user moves the page {string} to the trash", async (ctx: SpaceWorld, title: string) => {
  await selectPage(ctx, title);
  await press(ctx, "d");
  expect(status(ctx).text).toBe("Moved to the trash: r restores it.");
});

step("the trash of {string} holds {string}", async (ctx: SpaceWorld, name: string, titles) => {
  await openSpace(ctx, name);
  expect(listed(pane(ctx).rows, "trashed")).toEqual(list(titles));
});

step("the page {string} is in the trash", (ctx: SpaceWorld, title: string) => {
  mc(ctx).run("space.page.trash", { spaceId: currentSpaceId(ctx), pageId: seedPage(ctx, title) });
});

step("the user restores the page {string}", async (ctx: SpaceWorld, title: string) => {
  await selectPage(ctx, title);
  await press(ctx, "r");
});

// A trashed page opens to be read; a block written there is the MC's to refuse.
step(
  "the user writes {string} on the page {string}",
  async (ctx: SpaceWorld, text: string, title: string) => {
    await openPage(ctx, title);
    await press(ctx, "n");
    await choose(ctx, "Paragraph");
    await answer(ctx, text);
  },
);

step("the user deletes the page {string} for good", async (ctx: SpaceWorld, title: string) => {
  await selectPage(ctx, title);
  await press(ctx, "D");
  await choose(ctx, "Delete for good");
});

step(
  "no blocks or comments of {string} or {string} remain",
  async (ctx: SpaceWorld, a: string, b: string) => {
    for (const title of [a, b]) {
      const id = ctx.pageIds!.get(title)!;
      expect(mc(ctx).blocksOf(id)).toEqual([]);
      expect(mc(ctx).commentsOf(id)).toEqual([]);
      expect(pane(ctx).rows.some((row) => row.key.endsWith(`:${id}`))).toBe(false);
    }
  },
);

// --- blocks ---

const BLOCK_LABELS: Record<string, string> = {
  paragraph: "Paragraph",
  heading: "Heading",
  checklist: "Checklist item",
  callout: "Callout",
};

/** Add a block after the selected one (the last, unless `after` names one). */
async function addBlock(ctx: SpaceWorld, page: string, kind: string, text: string, after?: string) {
  await openPage(ctx, page);
  const rows = pane(ctx).rows.filter((row) => row.kind === "block");
  const anchor = after ? blockKey(ctx, after) : rows.at(-1)?.key;
  if (anchor) await selectRow(ctx, anchor);
  await press(ctx, "n");
  await choose(ctx, BLOCK_LABELS[kind]!);
  await answer(ctx, text);
}

step(
  "the user adds a {word} block {string} to {string}",
  (ctx: SpaceWorld, kind: string, text: string, page: string) => addBlock(ctx, page, kind, text),
);

step(
  "{string} has a {word} block {string}",
  async (ctx: SpaceWorld, page: string, kind: string, text: string) => {
    const rows = await blockRows(ctx, page);
    expect(rows.map((row) => [row.blockKind, blockText(row)])).toContainEqual([kind, text]);
  },
);

step("the user links {string} from {string}", async (ctx: SpaceWorld, child: string, page) => {
  await openPage(ctx, page);
  await press(ctx, "l");
  await choose(ctx, child);
});

step("{string} links to {string}", async (ctx: SpaceWorld, page: string, child: string) => {
  const rows = await blockRows(ctx, page);
  const link = rows.find((row) => row.blockKind === "subpage_link");
  expect(link && words(link)).toBe(`↳ ${child}`);
  // Following the link opens the subpage.
  await selectRow(ctx, link!.key);
  await press(ctx, "Enter");
  expect(pane(ctx).title).toBe(`page · ${child}`);
});

step("{string} has the blocks {string}", (ctx: SpaceWorld, page: string, texts: string) => {
  for (const text of list(texts)) seedBlock(ctx, page, "paragraph", text);
});

step(
  "the user adds {string} after {string} on {string}",
  (ctx: SpaceWorld, text: string, after: string, page: string) =>
    addBlock(ctx, page, "paragraph", text, after),
);

step("the blocks of {string} read {string}", async (ctx: SpaceWorld, page: string, texts) => {
  expect((await blockRows(ctx, page)).map(blockText)).toEqual(list(texts));
});

async function selectBlock(ctx: SpaceWorld, text: string) {
  const block = mc(ctx).blockNamed(text);
  await openPage(ctx, mc(ctx).pageNamed(pageTitle(ctx, block.pageId)).title);
  await selectRow(ctx, blockKey(ctx, text));
}

const pageTitle = (ctx: SpaceWorld, id: string) =>
  mc(ctx)
    .pagesOf(currentSpaceId(ctx))
    .find((page) => page.id === id)!.title as string;

step("the user changes the block {string} to {string}", async (ctx: SpaceWorld, from, to) => {
  await selectBlock(ctx, from);
  await press(ctx, "e");
  expect(findObject(ctx, "askInput").get("text")).toBe(from);
  await answer(ctx, to);
});

step("{string} has the checklist item {string}", (ctx: SpaceWorld, page: string, text) => {
  seedBlock(ctx, page, "checklist", text);
});

const tick = async (ctx: SpaceWorld, text: string) => {
  await selectBlock(ctx, text);
  await press(ctx, "x");
};

step("the user ticks {string}", tick);
step("the user unticks {string}", tick);

const blockRow = (ctx: World, key: string) =>
  pane(ctx).rows.find((row) => row.key === key && row.first);

step("{string} is ticked", async (ctx: SpaceWorld, text: string) => {
  const row = blockRow(ctx, blockKey(ctx, text));
  expect(row?.checked).toBe(true);
  expect(words(row!)).toBe(`[x] ${text}`);
});

step("{string} is not ticked", async (ctx: SpaceWorld, text: string) => {
  const row = blockRow(ctx, blockKey(ctx, text));
  expect(row?.checked).toBe(false);
  expect(words(row!)).toBe(`[ ] ${text}`);
});

step(
  "the user moves the block {string} before {string}",
  async (ctx: SpaceWorld, text: string, before: string) => {
    await selectBlock(ctx, text);
    await press(ctx, "m");
    await choose(ctx, `Before “${before}”`);
  },
);

step("only the block {string} changed", (ctx: SpaceWorld, text: string) => {
  const id = mc(ctx).blockNamed(text).id;
  expect(mc(ctx).lastChanges.map(([kind, changed]) => [kind, changed])).toEqual([["block", id]]);
});

step("the user deletes the block {string}", async (ctx: SpaceWorld, text: string) => {
  await selectBlock(ctx, text);
  await press(ctx, "d");
});

// --- comments ---

step(
  "the user comments {string} on the block {string}",
  async (ctx: SpaceWorld, body: string, text: string) => {
    await selectBlock(ctx, text);
    await press(ctx, "c");
    await answer(ctx, body);
  },
);

/** The comment rows right under a block, in the order shown. */
function commentsUnder(ctx: SpaceWorld, text: string) {
  const rows = pane(ctx).rows;
  const key = blockKey(ctx, text);
  let at = rows.findLastIndex((row) => row.key === key) + 1;
  const out: TuiSpaceRow[] = [];
  while (rows[at]?.kind === "comment") out.push(rows[at++]!);
  return out;
}

step(
  "the block {string} has the open comment {string}",
  async (ctx: SpaceWorld, text: string, body: string) => {
    await selectBlock(ctx, text);
    const comments = commentsUnder(ctx, text);
    expect(comments.map((row) => [words(row), row.resolved])).toContainEqual([`┊ ${body}`, false]);
  },
);

step("the comment {string} on the block {string}", (ctx: SpaceWorld, body: string, text) => {
  const block = mc(ctx).blockNamed(text);
  mc(ctx).run("space.comment.add", {
    spaceId: currentSpaceId(ctx),
    pageId: block.pageId,
    blockId: block.id,
    body,
  });
});

step("the comment {string} is resolved already", (ctx: SpaceWorld, body: string) => {
  mc(ctx).run("space.comment.resolve", {
    spaceId: currentSpaceId(ctx),
    commentId: mc(ctx).commentNamed(body).id,
  });
});

const toggleComment = async (ctx: SpaceWorld, body: string) => {
  const comment = mc(ctx).commentNamed(body);
  await openPage(ctx, pageTitle(ctx, comment.pageId));
  await selectRow(ctx, commentKey(ctx, body));
  await press(ctx, "x");
};

step("the user resolves the comment {string}", toggleComment);
step("the user reopens the comment {string}", toggleComment);

step("the comment {string} is resolved", (ctx: SpaceWorld, body: string) => {
  const row = pane(ctx).rows.find((entry) => entry.key === commentKey(ctx, body));
  expect(row?.resolved).toBe(true);
  expect(words(row!)).toBe(`┊ ✓ ${body} (resolved)`);
});

// --- Markdown ---

/** Table rows (after the header) as block specs. */
const tableBlocks = (table: string[][]) =>
  table.slice(1).map(([kind, text, checked]) => ({
    kind: kind!,
    text: text!,
    checked: checked === "yes",
  }));

step("the page {string} with the blocks:", (ctx: SpaceWorld, title: string, table: string[][]) => {
  for (const block of tableBlocks(table)) {
    seedBlock(ctx, title, block.kind, block.text, block.checked);
  }
});

step("the user exports {string} as Markdown", async (ctx: SpaceWorld, title: string) => {
  await openPage(ctx, title);
  await press(ctx, "y");
  expect(status(ctx).text).toBe(`Copied “${title}” as Markdown.`);
});

step("the Markdown is:", (ctx: SpaceWorld, markdown: string) => {
  expect(ctx.clipboard?.at(-1)).toBe(`${markdown}\n`);
});

// From a file on this machine, as the user would.
step(
  "the user imports this Markdown into {string}:",
  async (ctx: SpaceWorld, name: string, markdown: string) => {
    const dir = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "space-import-"));
    ctx.cleanups.push(() => NodeFS.rmSync(dir, { recursive: true, force: true }));
    const file = NodePath.join(dir, "roadmap.md");
    NodeFS.writeFileSync(file, markdown);
    await openSpace(ctx, name);
    await press(ctx, "i");
    await answer(ctx, file);
  },
);

step("the page {string} has the blocks:", async (ctx: SpaceWorld, title: string, table) => {
  // The import opened the new page.
  expect(pane(ctx).title).toBe(`page · ${title}`);
  const rows = await blockRows(ctx, title);
  expect(
    rows.map((row) => ({
      kind: row.blockKind as string | undefined,
      text: blockText(row),
      checked: row.checked === true,
    })),
  ).toEqual(tableBlocks(table));
});

// --- a page from a thread ---

step("the thread {string} talked about a release plan", (ctx: SpaceWorld, title: string) => {
  threadNamed(ctx, title);
});

// --- a page that updates itself (space/self-updating-pages.feature) ---

const updateRow = async (ctx: SpaceWorld, title: string, part: string) => {
  await openPage(ctx, title);
  return pane(ctx)
    .rows.filter((row) => row.key === `label:update:${part}`)
    .map((row) => row.text.trim())
    .join(" ");
};

/** The update asked for through its key: the instruction, then the cadence. */
async function askUpdate(ctx: SpaceWorld, page: string, instruction: string) {
  await openPage(ctx, page);
  await press(ctx, "u");
  if (mode(ctx) === "select") await choose(ctx, "Change it…");
  await answer(ctx, instruction);
}

async function updateMenu(ctx: SpaceWorld, page: string, label: string) {
  await openPage(ctx, page);
  await press(ctx, "u");
  await choose(ctx, label);
}

const onPage = (ctx: SpaceWorld, title: string) => ({
  spaceId: currentSpaceId(ctx),
  pageId: pageId(ctx, title),
});

const everyHours = (hours: number) => ({ type: "interval", everyMs: hours * 3_600_000 });

step(
  "the user has {string} update itself with {string} every {int} hours",
  async (ctx: SpaceWorld, page: string, instruction: string, hours: number) => {
    await askUpdate(ctx, page, instruction);
    await choose(ctx, `Every ${hours} hours`);
  },
);

step(
  "the user has {string} update itself with {string} every day at {string}",
  async (ctx: SpaceWorld, page: string, instruction: string, time: string) => {
    await askUpdate(ctx, page, instruction);
    await choose(ctx, "At a time of day…");
    await answer(ctx, time);
  },
);

step(
  "{string} updates itself with {string} every {int} hours",
  (ctx: SpaceWorld, page: string, instruction: string, hours: number) => {
    mc(ctx).run("space.page.schedule.set", {
      ...onPage(ctx, page),
      instruction,
      cadence: everyHours(hours),
    });
  },
);

step("the updates of {string} are paused", (ctx: SpaceWorld, page: string) => {
  mc(ctx).run("space.page.schedule.setEnabled", { ...onPage(ctx, page), enabled: false });
});

step("the update of {string} has run", (ctx: SpaceWorld, page: string) => {
  mc(ctx).run("space.page.schedule.runNow", onPage(ctx, page));
});

step("text generation writes {string}", (ctx: SpaceWorld, markdown: string) => {
  mc(ctx).generation = { kind: "available", title: "", markdown };
});

step("the user pauses the updates of {string}", (ctx: SpaceWorld, page: string) =>
  updateMenu(ctx, page, "Pause it"),
);
step("the user resumes the updates of {string}", (ctx: SpaceWorld, page: string) =>
  updateMenu(ctx, page, "Resume it"),
);
step("the user runs the update of {string} now", (ctx: SpaceWorld, page: string) =>
  updateMenu(ctx, page, "Run it now"),
);
step("the user removes the update of {string}", (ctx: SpaceWorld, page: string) =>
  updateMenu(ctx, page, "Remove it, keeping what it wrote"),
);

// The pane says why without asking the MC, and leaves the part as it is.
step(
  "the user tries to edit the generated part of {string}",
  async (ctx: SpaceWorld, page: string) => {
    await openPage(ctx, page);
    const part = pane(ctx).rows.find((row) => row.blockKind === "generated");
    expect(part).toBeDefined();
    await selectRow(ctx, part!.key);
    await press(ctx, "e");
    expect(mode(ctx)).not.toBe("ask");
    expect(status(ctx).text).toStartWith("A page's update wrote this");
  },
);

step(
  "{string} shows the instruction {string}",
  async (ctx: SpaceWorld, page: string, instruction) => {
    expect(await updateRow(ctx, page, "instruction")).toBe(`⟳ ${instruction}`);
  },
);
step("{string} shows no instruction", async (ctx: SpaceWorld, page: string) => {
  expect(await updateRow(ctx, page, "instruction")).toBe("");
});
step(
  "{string} shows it updates every {int} hours",
  async (ctx: SpaceWorld, page: string, hours: number) => {
    expect(await updateRow(ctx, page, "when")).toStartWith(`Every ${hours} hours`);
  },
);
step(
  "{string} shows it updates every day at {string}",
  async (ctx: SpaceWorld, page: string, time) => {
    expect(await updateRow(ctx, page, "when")).toStartWith(`${time} every day`);
  },
);
step("{string} shows when it next runs", async (ctx: SpaceWorld, page: string) => {
  expect(await updateRow(ctx, page, "when")).toContain("next run ");
});
step("{string} shows no next run", async (ctx: SpaceWorld, page: string) => {
  expect(await updateRow(ctx, page, "when")).not.toContain("next run ");
});
step("{string} has not been written yet", async (ctx: SpaceWorld, page: string) => {
  expect(await updateRow(ctx, page, "written")).toBe("Not written yet");
});
step("{string} shows when it was last written", async (ctx: SpaceWorld, page: string) => {
  expect(await updateRow(ctx, page, "written")).toStartWith("Last written ");
});
step("{string} shows its updates are paused", async (ctx: SpaceWorld, page: string) => {
  expect(await updateRow(ctx, page, "when")).toEndWith(" · paused");
});
step("{string} shows its updates are not paused", async (ctx: SpaceWorld, page: string) => {
  expect(await updateRow(ctx, page, "when")).not.toContain("paused");
});
step(
  "{string} shows its last run failed with {string}",
  async (ctx: SpaceWorld, page: string, message) => {
    expect(await updateRow(ctx, page, "failed")).toBe(`Last run failed: ${message}`);
  },
);
step(
  "the generated part of {string} reads {string}",
  async (ctx: SpaceWorld, page: string, text) => {
    const rows = await blockRows(ctx, page);
    expect(rows.filter((row) => row.blockKind === "generated").map(blockText)).toEqual([text]);
  },
);
step("{string} has no generated part", async (ctx: SpaceWorld, page: string) => {
  const rows = await blockRows(ctx, page);
  expect(rows.filter((row) => row.blockKind === "generated")).toEqual([]);
});

step("text generation is available", (ctx: SpaceWorld) => {
  mc(ctx).generation = { kind: "available", title: SUMMARY_TITLE, markdown: SUMMARY };
});

step("no text generation provider is available", (ctx: SpaceWorld) => {
  mc(ctx).generation = { kind: "unavailable", message: UNAVAILABLE };
});

step("text generation fails", (ctx: SpaceWorld) => {
  mc(ctx).generation = { kind: "failed", message: FAILED };
});

step(
  "the user makes a page in {string} from the thread {string}",
  async (ctx: SpaceWorld, name: string, thread: string) => {
    await openSpace(ctx, name);
    await press(ctx, "t");
    await choose(ctx, thread);
  },
);

step("the new page holds the generated summary", async (ctx: SpaceWorld) => {
  expect(status(ctx).text).toBe(`Wrote “${SUMMARY_TITLE}”.`);
  expect(pane(ctx).view).toBe("page");
  const rows = pane(ctx).rows.filter((row) => row.kind === "block" && row.first);
  expect(rows.map(blockText)).toEqual([
    "Goals",
    "Ship pages in July.",
    "Cut the branch",
    "Write the notes",
  ]);
});

step("the new page remembers it came from {string}", (ctx: SpaceWorld, thread: string) => {
  expect(pane(ctx).title).toBe(`page · ${SUMMARY_TITLE} · from ${thread}`);
  expect(mc(ctx).pageNamed(SUMMARY_TITLE).sourceThreadId).toBe(threadNamed(ctx, thread).id);
  // The agent wrote it: each block names its thread.
  const rows = pane(ctx).rows.filter((row) => row.kind === "block");
  expect(rows.at(-1)!.text.endsWith(`· ${thread}`)).toBe(true);
});

step("the summary was written in the project's folder", (ctx: SpaceWorld) => {
  const thread = env(ctx).threads[0]!;
  const project = env(ctx).projects.find((entry) => entry.id === thread.projectId)!;
  expect(mc(ctx).summaries).toEqual([
    { threadId: thread.id, cwd: projectNamed(ctx, project.title).workspaceRoot },
  ]);
});

step("the user is told text generation is unavailable", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(status(ctx).text).toBe(
    `Text generation is unavailable, so no page was made: ${UNAVAILABLE}`,
  );
});

step("the user is told text generation failed", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(status(ctx).text).toBe(`Text generation failed, so no page was made: ${FAILED}`);
});

// --- charts ---

const FROM_THIS_PAGE = "Numbers from this page";
const COUNTED = "Counted by this MC from its 2 threads, 12 weeks to 2026-11-01";
const AVAILABLE = { kind: "available", title: "", markdown: "" } as const;

const chartOf = (
  type: string,
  title: string,
  source: string,
  points: ReadonlyArray<readonly [string, number]>,
) => ({
  type,
  title,
  source,
  labels: points.map(([label]) => label),
  series: [{ name: title, values: points.map(([, value]) => value) }],
});

/** The page the scenario's chart is on, for the steps that do not name it. */
const chartPage = (ctx: SpaceWorld) => mc(ctx).pagesOf(currentSpaceId(ctx))[0]!.title as string;

function seedChart(
  ctx: SpaceWorld,
  page: string,
  points: ReadonlyArray<readonly [string, number]>,
  values = points.map(([, value]) => value),
) {
  const before = mc(ctx).generation;
  mc(ctx).generation = AVAILABLE;
  mc(ctx).chart = {
    ...chartOf("bar", "Signups", FROM_THIS_PAGE, points),
    series: [{ name: "Signups", values }],
  };
  mc(ctx).run("space.block.visualize", {
    spaceId: currentSpaceId(ctx),
    pageId: seedPage(ctx, page),
    request: "signups",
  });
  mc(ctx).chart = null;
  mc(ctx).generation = before;
}

/** Every row the chart on the open page draws. */
async function chartDrawn(ctx: SpaceWorld) {
  await openPage(ctx, chartPage(ctx));
  return pane(ctx).rows.filter((row) => row.blockKind === "chart");
}

/** What the chart's rows read as label and number, whichever way it is drawn. */
const numbersOf = (rows: ReadonlyArray<TuiSpaceRow>) =>
  rows.flatMap((row) => {
    const match = /^\s+(\S+)\s+[█▏▎▍▌▋▊▉]*\s*(\d+)$/.exec(row.text);
    return match ? [[match[1], Number(match[2])]] : [];
  });

const answerChart = (ctx: World, request: string) =>
  answer(ctx, request.replace(/^\/visualize\s*/, ""));

const selectChart = async (ctx: SpaceWorld) => {
  const [title] = await chartDrawn(ctx);
  expect(title).toBeDefined();
  await selectRow(ctx, title!.key);
};

step("this MC's threads took turns this week", () => {});

step("text generation charts the request from the MC's threads", (ctx: SpaceWorld) => {
  mc(ctx).generation = AVAILABLE;
  mc(ctx).chart = chartOf("bar", "Weekly turns", COUNTED, [
    ["10-26", 4],
    ["11-02", 7],
  ]);
});

step(
  "text generation answers with a {word} chart of {string} {int}",
  (ctx: SpaceWorld, type: string, label: string, value: number) => {
    mc(ctx).generation = AVAILABLE;
    mc(ctx).chart = chartOf(type, "Signups", FROM_THIS_PAGE, [[label, value]]);
  },
);

step(
  "text generation answers with a {word} chart of {string} {int} and {string} {int}",
  (ctx: SpaceWorld, type: string, a: string, x: number, b: string, y: number) => {
    mc(ctx).generation = AVAILABLE;
    mc(ctx).chart = chartOf(type, "Signups", FROM_THIS_PAGE, [
      [a, x],
      [b, y],
    ]);
  },
);

step("text generation says the request cannot be answered", (ctx: SpaceWorld) => {
  mc(ctx).generation = AVAILABLE;
  mc(ctx).chart = null;
});

step(
  "the page {string} has a chart of {string} {int} and {string} {int}",
  (ctx: SpaceWorld, page: string, a: string, x: number, b: string, y: number) => {
    seedChart(ctx, page, [
      [a, x],
      [b, y],
    ]);
  },
);

step(
  "the page {string} has the blocks {string} and a chart of {string} {int} and {string} {int} and the blocks {string}",
  (
    ctx: SpaceWorld,
    page: string,
    before: string,
    a: string,
    x: number,
    b: string,
    y: number,
    after,
  ) => {
    seedBlock(ctx, page, "paragraph", before);
    seedChart(ctx, page, [
      [a, x],
      [b, y],
    ]);
    seedBlock(ctx, page, "paragraph", after);
  },
);

step("{string} also says {string}", (ctx: SpaceWorld, page: string, text: string) => {
  seedBlock(ctx, page, "paragraph", text);
});

step(
  "the user asks for {string} on the page {string}",
  async (ctx: SpaceWorld, request: string, page: string) => {
    await openPage(ctx, page);
    await press(ctx, "n");
    await choose(ctx, "Chart");
    await answerChart(ctx, request);
  },
);

step("the user asks again for {string}", async (ctx: SpaceWorld, request: string) => {
  await selectChart(ctx);
  await press(ctx, "g");
  // It starts from the words the chart was asked for in.
  expect(findObject(ctx, "askInput").get("text")).toBe("signups");
  await answerChart(ctx, request);
});

step(
  "the page shows a {word} chart titled {string}",
  async (ctx: SpaceWorld, type: string, title: string) => {
    const rows = await chartDrawn(ctx);
    expect(rows[0] && words(rows[0])).toBe(title);
    // Bars for a bar chart, a table with no bars for a line.
    expect(rows.some((row) => row.text.includes("█"))).toBe(type === "bar");
  },
);

step(
  /^the chart says its numbers came from (this MC's threads|this page)$/,
  async (ctx: SpaceWorld, where: string) => {
    const shown = (await chartDrawn(ctx)).map(words).join(" ");
    expect(shown.endsWith(where === "this page" ? FROM_THIS_PAGE : COUNTED)).toBe(true);
  },
);

step("the second client sees a chart titled {string}", async (ctx: SpaceWorld, title: string) => {
  await ctx.second!.settled();
  const row = secondPane(ctx).rows.find((one) => one.blockKind === "chart");
  expect(row && words(row)).toBe(title);
});

step(
  "the page {string} has a chart with 2 labels and 1 number",
  (ctx: SpaceWorld, page: string) => {
    seedChart(
      ctx,
      page,
      [
        ["May", 3],
        ["June", 5],
      ],
      [3],
    );
  },
);

step("the chart's numbers are not shown", async (ctx: SpaceWorld) => {
  const rows = await chartDrawn(ctx);
  expect(rows.map(words).join(" ")).toContain("a chart");
  expect(numbersOf(rows)).toEqual([]);
});

// A terminal draws a chart's numbers beside it: there is nothing to open, only the chart to read.
step("the user asks to see the numbers behind the chart", selectChart);

step("the numbers read {string} {int}", async (ctx: SpaceWorld, label: string, value: number) => {
  expect(numbersOf(await chartDrawn(ctx))).toEqual([[label, value]]);
});

step(
  "the numbers read {string} {int} and {string} {int}",
  async (ctx: SpaceWorld, a: string, x: number, b: string, y: number) => {
    expect(numbersOf(await chartDrawn(ctx))).toEqual([
      [a, x],
      [b, y],
    ]);
  },
);

step(
  "the page shows one chart, between {string} and {string}",
  async (ctx: SpaceWorld, before: string, after: string) => {
    const rows = await blockRows(ctx, chartPage(ctx));
    expect(rows.filter((row) => row.blockKind === "chart")).toHaveLength(1);
    const at = rows.findIndex((row) => row.blockKind === "chart");
    expect([words(rows[at - 1]!), words(rows[at + 1]!)]).toEqual([before, after]);
  },
);

step("the user deletes the chart", async (ctx: SpaceWorld) => {
  await selectChart(ctx);
  await press(ctx, "d");
});

step("the page shows no chart", async (ctx: SpaceWorld) => {
  expect(await chartDrawn(ctx)).toEqual([]);
});

step("the user is told no chart was drawn", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(status(ctx).kind).toBe("error");
  expect(status(ctx).text.startsWith("No chart was drawn")).toBe(true);
});

// --- agents ---

/** An agent's MCP tool writes to the MC while the user reads the page. */
async function asAgent(
  ctx: SpaceWorld,
  thread: string,
  page: string,
  method: string,
  input: object,
) {
  await openPage(ctx, page);
  mc(ctx).run(method, { spaceId: currentSpaceId(ctx), ...input }, agent(ctx, thread));
  await settle(ctx);
}

step(
  "the agent in {string} adds the block {string} to {string}",
  (ctx: SpaceWorld, thread: string, text: string, page: string) =>
    asAgent(ctx, thread, page, "space.block.insert", {
      pageId: pageId(ctx, page),
      kind: "paragraph",
      text,
    }),
);

step(
  "the block {string} was written by the thread {string}",
  (ctx: SpaceWorld, text: string, thread: string) => {
    const rows = pane(ctx).rows.filter((row) => row.key === blockKey(ctx, text));
    expect(rows.at(-1)!.text.endsWith(`${text}  · ${thread}`)).toBe(true);
  },
);

step(
  "the agent in {string} changes the block {string} to {string}",
  (ctx: SpaceWorld, thread: string, from: string, to: string) => {
    const block = mc(ctx).blockNamed(from);
    return asAgent(ctx, thread, pageTitle(ctx, block.pageId), "space.block.update", {
      blockId: block.id,
      text: to,
    });
  },
);

step(
  "the agent in {string} deletes the block {string}",
  (ctx: SpaceWorld, thread: string, text: string) => {
    const block = mc(ctx).blockNamed(text);
    return asAgent(ctx, thread, pageTitle(ctx, block.pageId), "space.block.delete", {
      blockId: block.id,
    });
  },
);

// --- a page's history ---

const versionRows = (ctx: World) => pane(ctx).rows.filter((row) => row.kind === "version");

async function openHistory(ctx: SpaceWorld, title: string) {
  ctx.historyPage = title;
  if (pane(ctx)?.view === "history" && pane(ctx).title === `history · ${title}`) return;
  await openPage(ctx, title);
  await press(ctx, "h");
  expect(pane(ctx).view).toBe("history");
}

/** Back on the history the scenario opened, wherever the last step left the pane. */
const onHistory = (ctx: SpaceWorld) => openHistory(ctx, ctx.historyPage!);

async function selectVersion(ctx: SpaceWorld, back: number, title: string) {
  await openHistory(ctx, title);
  await selectRow(ctx, versionRows(ctx)[back]!.key);
}

const versionBlocks = (ctx: World) =>
  pane(ctx)
    .rows.filter((row) => row.kind === "block" && row.first)
    .map(blockText);

step("a while passes", (ctx: SpaceWorld) => {
  mc(ctx).aWhilePasses();
});

step("the user opens the history of {string}", openHistory);

const historyHas = async (ctx: SpaceWorld, count: number) => {
  await onHistory(ctx);
  expect(versionRows(ctx)).toHaveLength(count);
};
step("the history has {int} versions", historyHas);
step("the history has {int} version", historyHas);

step("each version says when it was written and by the user", (ctx: SpaceWorld) => {
  for (const row of versionRows(ctx)) {
    expect(words(row)).toMatch(/^\d{4}-\d\d-\d\d \d\d:\d\d {2}You/);
  }
});

step("the newest version is the page as it is now", async (ctx: SpaceWorld) => {
  expect(words(versionRows(ctx)[0]!)).toContain("· current");
  const asItIs = mc(ctx)
    .blocksOf(pageId(ctx, ctx.historyPage!))
    .map((block) => block.text);
  await selectRow(ctx, versionRows(ctx)[0]!.key);
  await press(ctx, "Enter");
  expect(versionBlocks(ctx)).toEqual(asItIs);
  await press(ctx, "Esc");
});

step("the newest version was written by the thread {string}", (ctx: SpaceWorld, thread: string) => {
  expect(words(versionRows(ctx)[0]!)).toContain(thread);
});

step("the newest version was written by the page's update", (ctx: SpaceWorld) => {
  expect(words(versionRows(ctx)[0]!)).toContain("The page's update");
});

step(
  "the user reads the version {int} back on {string}",
  async (ctx: SpaceWorld, back: number, title: string) => {
    await selectVersion(ctx, back, title);
    await press(ctx, "Enter");
    expect(pane(ctx).view).toBe("version");
  },
);

step("the version reads {string}", (ctx: SpaceWorld, texts: string) => {
  expect(pane(ctx).view).toBe("version");
  expect(versionBlocks(ctx)).toEqual(list(texts));
});

step(
  "the version draws a chart of {string} {int} and {string} {int}",
  (ctx: SpaceWorld, first: string, a: number, next: string, b: number) => {
    expect(pane(ctx).view).toBe("version");
    const rows = pane(ctx).rows.filter((row) => row.blockKind === "chart");
    expect(numbersOf(rows)).toEqual([
      [first, a],
      [next, b],
    ]);
  },
);

step("the version shows the image {string}", (ctx: SpaceWorld, name: string) => {
  expect(versionBlocks(ctx)).toContain(`[image: ${name}]`);
});

step("the version says the image {string} is in the trash", async (ctx: SpaceWorld, name) => {
  await settle(ctx);
  expect(versionBlocks(ctx)).toContain(`[image: ${name} is in the trash]`);
});

step("the user goes back to the list of versions", (ctx: SpaceWorld) => press(ctx, "Esc"));

step("no version is being read", (ctx: SpaceWorld) => {
  expect(pane(ctx).view).toBe("history");
});

step(
  "the user restores the version {int} back on {string}",
  async (ctx: SpaceWorld, back: number, title: string) => {
    await selectVersion(ctx, back, title);
    await press(ctx, "r");
  },
);

step("the newest version says it restored an earlier one", async (ctx: SpaceWorld) => {
  await onHistory(ctx);
  expect(words(versionRows(ctx)[0]!)).toContain("restored from");
});

// The pane says why without asking the MC, which would refuse it.
step("the user cannot restore a version of {string}", async (ctx: SpaceWorld, title: string) => {
  await selectVersion(ctx, 1, title);
  await press(ctx, "r");
  expect(mc(ctx).refusals).toEqual([]);
  expect(status(ctx)).toEqual(
    expect.objectContaining({
      text: "This page is in the trash: restore it to bring back a version.",
      kind: "info",
    }),
  );
  expect(
    mc(ctx)
      .blocksOf(pageId(ctx, title))
      .map((block) => block.text),
  ).toEqual(["Final"]);
});

// --- decks ---

/** A deck seeded through the MC, with its blank slide. */
function seedDeck(ctx: SpaceWorld, title: string) {
  const existing = mc(ctx)
    .decksOf(currentSpaceId(ctx))
    .find((deck) => deck.title === title);
  if (existing) return existing.id as string;
  return mc(ctx).run("space.deck.create", { spaceId: currentSpaceId(ctx), title }).deck
    .id as string;
}

const deckRowKey = (ctx: SpaceWorld, title: string) => {
  const deck = mc(ctx).deckNamed(title);
  return `${deck.trashedAt === null ? "deck" : "decktrash"}:${deck.id}`;
};

async function selectDeck(ctx: SpaceWorld, title: string) {
  await openSpace(ctx);
  await selectRow(ctx, deckRowKey(ctx, title));
}

async function openDeck(ctx: SpaceWorld, title: string) {
  await start(ctx);
  const view = pane(ctx);
  if (view.open && view.view === "deck" && view.title.startsWith(`deck · ${title}`)) return;
  await selectDeck(ctx, title);
  await press(ctx, "Enter");
  expect(pane(ctx).view).toBe("deck");
}

/** The slides of the open deck as shown: `[title, body]`, its lines apart by " / ". */
const slideTable = (rows: ReadonlyArray<TuiSpaceRow>) => {
  const out: string[][] = [];
  for (const row of rows.filter((entry) => entry.kind === "slide")) {
    if (row.first)
      out.push([
        words(row)
          .replace(/^\d+\. /, "")
          .replace("(untitled)", ""),
        "",
      ]);
    else {
      const last = out.at(-1)!;
      last[1] = last[1] === "" ? row.text.trim() : `${last[1]} / ${row.text.trim()}`;
    }
  }
  return out;
};

async function openSlide(ctx: SpaceWorld, title: string) {
  const slide = mc(ctx).slideNamed(title);
  const deck = mc(ctx)
    .decksOf(currentSpaceId(ctx))
    .find((entry) => entry.id === slide.deckId)!;
  await openDeck(ctx, deck.title);
  await selectRow(ctx, `slide:${slide.id}`);
}

step("the user makes the deck {string}", async (ctx: SpaceWorld, title: string) => {
  await openSpace(ctx);
  await press(ctx, "s");
  await answer(ctx, title);
});

step("the user makes a deck from the page {string}", async (ctx: SpaceWorld, title: string) => {
  await selectPage(ctx, title);
  await press(ctx, "S");
});

step("the deck {string}", (ctx: SpaceWorld, title: string) => {
  seedDeck(ctx, title);
});

step("the deck {string} with the slides {string}", (ctx: SpaceWorld, title: string, slides) => {
  const deckId = seedDeck(ctx, title);
  const spaceId = currentSpaceId(ctx);
  for (const slide of mc(ctx)
    .slides()
    .filter((entry) => entry.deckId === deckId)) {
    mc(ctx).run("space.slide.delete", { spaceId, slideId: slide.id });
  }
  for (const name of list(slides))
    mc(ctx).run("space.slide.insert", { spaceId, deckId, title: name });
});

step("the deck {string} is in the trash", (ctx: SpaceWorld, title: string) => {
  mc(ctx).run("space.deck.trash", { spaceId: currentSpaceId(ctx), deckId: seedDeck(ctx, title) });
});

step("the decks of {string} are {string}", async (ctx: SpaceWorld, name: string, titles) => {
  await openSpace(ctx, name);
  expect(listed(pane(ctx).rows, "deck")).toEqual(list(titles));
});

step("the deck {string} has the slides:", async (ctx: SpaceWorld, title: string, table) => {
  await openDeck(ctx, title);
  expect(slideTable(pane(ctx).rows)).toEqual(
    (table as string[][]).slice(1).map((row) => [row[0] ?? "", row[1] ?? ""]),
  );
});

const slidesAre = async (ctx: SpaceWorld, title: string, titles: string) => {
  await openDeck(ctx, title);
  expect(slideTable(pane(ctx).rows).map((row) => row[0])).toEqual(list(titles));
};

step("the slides of {string} are {string}", slidesAre);
step("the slides of {string} are still {string}", slidesAre);

step("the user renames the deck {string} to {string}", async (ctx: SpaceWorld, from, to) => {
  await selectDeck(ctx, from);
  await press(ctx, "e");
  expect(findObject(ctx, "askInput").get("text")).toBe(from);
  await answer(ctx, to);
});

step("the user moves the deck {string} to the trash", async (ctx: SpaceWorld, title: string) => {
  await selectDeck(ctx, title);
  await press(ctx, "d");
  expect(status(ctx).text).toBe("Moved to the trash: r restores it.");
});

step("the user restores the deck {string}", async (ctx: SpaceWorld, title: string) => {
  await selectDeck(ctx, title);
  await press(ctx, "r");
});

step("the user deletes the deck {string} for good", async (ctx: SpaceWorld, title: string) => {
  await selectDeck(ctx, title);
  await press(ctx, "D");
  await choose(ctx, "Delete for good");
});

// --- sites ---

const siteLink = (ctx: SpaceWorld, title: string) => {
  const site = mc(ctx).siteOf(title);
  expect(site).toBeDefined();
  (ctx.siteLinks ??= new Map()).set(title, site!.url);
  return site!.url as string;
};

const siteRowsOf = (state: TuiSpaceState) =>
  state.rows.filter((row) => row.kind === "label").map((row) => row.text);

step("the user publishes the page {string} as a site", async (ctx: SpaceWorld, title: string) => {
  await selectPage(ctx, title);
  await press(ctx, "p");
});

step("the user publishes the page {string} over Tailscale", async (ctx: SpaceWorld, title) => {
  await selectPage(ctx, title);
  await press(ctx, "P");
});

step("the page {string} is published as a site", (ctx: SpaceWorld, title: string) => {
  mc(ctx).run("space.page.publish", {
    spaceId: currentSpaceId(ctx),
    pageId: seedPage(ctx, title),
  });
  siteLink(ctx, title);
});

step("the page {string} shows it is published with a link", async (ctx: SpaceWorld, title) => {
  await openPage(ctx, title);
  expect(pane(ctx).title).toContain("· published");
  expect(siteRowsOf(pane(ctx)).join("\n")).toContain(siteLink(ctx, title));
});

step("the user copies the site link of the page {string}", async (ctx: SpaceWorld, title) => {
  await openPage(ctx, title);
  await press(ctx, "Y");
  expect(status(ctx).text).toBe("Site link copied.");
});

step("the site link of the page {string} is on the clipboard", (ctx: SpaceWorld, title) => {
  expect(ctx.clipboard?.at(-1)).toBe(siteLink(ctx, title));
});

step("the user unpublishes the page {string}", async (ctx: SpaceWorld, title: string) => {
  await openPage(ctx, title);
  await press(ctx, "U");
});

step("the page {string} shows it is not published", async (ctx: SpaceWorld, title: string) => {
  await openPage(ctx, title);
  expect(pane(ctx).title).not.toContain("published");
  expect(siteRowsOf(pane(ctx)).filter((text) => text.startsWith("Site:"))).toEqual([]);
});

step("the site link of the page {string} no longer opens", (ctx: SpaceWorld, title: string) => {
  expect(mc(ctx).siteOpens(ctx.siteLinks!.get(title)!)).toBe(false);
});

step("the second client sees the page {string} published", async (ctx: SpaceWorld, title) => {
  await ctx.second!.settled();
  expect(secondPane(ctx).title).toContain(title);
  expect(secondPane(ctx).title).toContain("· published");
  expect(siteRowsOf(secondPane(ctx)).join("\n")).toContain(mc(ctx).siteOf(title)!.url);
});

step("the page {string} shows its site is behind", async (ctx: SpaceWorld, title: string) => {
  await openPage(ctx, title);
  expect(pane(ctx).title).toContain("· published, behind");
  expect(siteRowsOf(pane(ctx))).toContain(SITE_BEHIND_HINT);
});

step("the page {string} shows its site is up to date", async (ctx: SpaceWorld, title: string) => {
  await openPage(ctx, title);
  expect(pane(ctx).title).toContain("· published");
  expect(pane(ctx).title).not.toContain("behind");
  expect(siteRowsOf(pane(ctx))).not.toContain(SITE_BEHIND_HINT);
});

step("the page {string} has the same site link", (ctx: SpaceWorld, title: string) => {
  expect(mc(ctx).siteOf(title)!.url).toBe(ctx.siteLinks!.get(title)!);
});

step("the MC listens only on this machine", (ctx: SpaceWorld) => {
  mc(ctx).siteAddress = "http://127.0.0.1:3773";
});

step(
  "the page {string} says only this machine can open its site link",
  async (ctx: SpaceWorld, title) => {
    await openPage(ctx, title);
    expect(siteRowsOf(pane(ctx))).toContain(SITE_LOCAL_ONLY_HINT);
  },
);

step("Tailscale names the MC's machine {string}", (ctx: SpaceWorld, name: string) => {
  mc(ctx).tailnetName = name;
});

step("the site link of the page {string} starts with {string}", (ctx: SpaceWorld, title, start) => {
  expect(siteLink(ctx, title).startsWith(start)).toBe(true);
});

// --- images ---

const IMAGE_UNAVAILABLE = "No image generation provider is set up.";
const IMAGE_FAILED = "The provider left no image.";
const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

async function openImages(ctx: SpaceWorld, name = ctx.spaceName!) {
  await openSpace(ctx, name);
  await press(ctx, "v");
  expect(pane(ctx).view).toBe("images");
}

/** An image's name, without the prompt after it. */
const imageName = (text: string) => text.split("  · ")[0]!;
const imageRows = (rows: ReadonlyArray<TuiSpaceRow>, kind: TuiSpaceRow["kind"]) =>
  listed(rows, kind).map(imageName);

const imageKey = (ctx: SpaceWorld, name: string) => {
  const { id } = mc(ctx).imageNamed(name);
  return pane(ctx).rows.some((row) => row.key === `imageTrash:${id}`)
    ? `imageTrash:${id}`
    : `image:${id}`;
};

async function selectImage(ctx: SpaceWorld, name: string) {
  await openImages(ctx);
  await selectRow(ctx, imageKey(ctx, name));
}

/** Add a file from this machine through the pane's field. */
async function addFile(ctx: SpaceWorld, name: string, bytes: Uint8Array, space: string) {
  const folder = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-tui-image-"));
  ctx.cleanups.push(() => NodeFS.rmSync(folder, { recursive: true, force: true }));
  const file = NodePath.join(folder, name);
  NodeFS.writeFileSync(file, bytes);
  await openImages(ctx, space);
  await press(ctx, "i");
  await answer(ctx, file);
}

step(
  "the user adds the image {string} to {string}",
  (ctx: SpaceWorld, name: string, space: string) => addFile(ctx, name, PNG, space),
);

step(
  "the user adds the file {string} holding plain text to {string}",
  (ctx: SpaceWorld, name: string, space: string) =>
    addFile(ctx, name, new TextEncoder().encode("only words"), space),
);

step("the images of {string} are {string}", async (ctx: SpaceWorld, space: string, names) => {
  await openImages(ctx, space);
  expect(imageRows(pane(ctx).rows, "image")).toEqual(list(names));
});

step(
  "the image trash of {string} holds {string}",
  async (ctx: SpaceWorld, space: string, names) => {
    await openImages(ctx, space);
    expect(imageRows(pane(ctx).rows, "trashedImage")).toEqual(list(names));
  },
);

// The pane refuses what is no image before sending it; the MC's refusals read the same.
step("the image request is refused", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(status(ctx).kind).toBe("error");
});

step("the second client sees the image {string}", async (ctx: SpaceWorld, name: string) => {
  await ctx.second!.settled();
  ctx.second!.dispatch("space.images");
  await ctx.second!.settled();
  expect(imageRows(secondPane(ctx).rows, "image")).toContain(name);
});

step("image generation is available", (ctx: SpaceWorld) => {
  mc(ctx).imageGeneration = { kind: "available" };
});

step("no image generation provider is available", (ctx: SpaceWorld) => {
  mc(ctx).imageGeneration = { kind: "unavailable", message: IMAGE_UNAVAILABLE };
});

step("image generation fails", (ctx: SpaceWorld) => {
  mc(ctx).imageGeneration = { kind: "failed", message: IMAGE_FAILED };
});

step(
  "the user generates an image of {string} in {string}",
  async (ctx: SpaceWorld, prompt: string, space: string) => {
    await openImages(ctx, space);
    await press(ctx, "n");
    await answer(ctx, prompt);
    await settle(ctx);
    if (mode(ctx) === "select") await choose(ctx, "codex");
    await settle(ctx);
  },
);

step("{string} has a generated image of {string}", (ctx: SpaceWorld, space: string, prompt) => {
  const images = mc(ctx).imagesOf(mc(ctx).spaceNamed(space).id);
  expect(images.map((image) => image.prompt)).toEqual([prompt]);
  expect(images[0]!.generatedBy.instanceId).toBe("codex");
});

step("the user is told image generation is unavailable", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(status(ctx)).toEqual(
    expect.objectContaining({
      text: `Image generation is unavailable, so no image was made: ${IMAGE_UNAVAILABLE}`,
      kind: "error",
    }),
  );
});

step("the user is told image generation failed", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(status(ctx)).toEqual(
    expect.objectContaining({
      text: `Image generation failed, so no image was made: ${IMAGE_FAILED}`,
      kind: "error",
    }),
  );
});

step("the image providers on offer say which can generate", async (ctx: SpaceWorld) => {
  await openImages(ctx);
  await press(ctx, "n");
  await answer(ctx, "a red fox");
  await settle(ctx);
  expect(mode(ctx)).toBe("select");
  const offered = select(ctx).options;
  expect(offered.find((option) => option.label === "codex")?.disabled).toBeFalsy();
  const notHere = offered.find((option) => option.label === "claudeAgent");
  expect(notHere?.disabled).toBe(true);
  expect(notHere?.description).toBe("not supported here");
  await press(ctx, "Esc");
  expect(mc(ctx).imagesOf(currentSpaceId(ctx))).toEqual([]);
});

step("the image {string} in {string}", (ctx: SpaceWorld, name: string, space: string) => {
  mc(ctx).seedImage(seedSpace(ctx, space), name);
});

step("the image {string} is in the image trash", (ctx: SpaceWorld, name: string) => {
  mc(ctx).run("space.image.trash", {
    spaceId: currentSpaceId(ctx),
    imageId: mc(ctx).imageNamed(name).id,
  });
});

step("{string} shows the image {string} already", (ctx: SpaceWorld, page: string, name: string) => {
  mc(ctx).run("space.block.insert", {
    spaceId: currentSpaceId(ctx),
    pageId: pageId(ctx, page),
    kind: "image",
    imageId: mc(ctx).imageNamed(name).id,
  });
});

step(
  "the user places the image {string} on {string}",
  async (ctx: SpaceWorld, name: string, page: string) => {
    const trashed = mc(ctx).imageNamed(name).trashedAt !== null;
    await openPage(ctx, page);
    await press(ctx, "n");
    await choose(ctx, "Image");
    await choose(ctx, trashed ? `${name} (in the trash)` : name);
  },
);

const expectBlock = async (ctx: SpaceWorld, page: string, text: string) => {
  expect((await blockRows(ctx, page)).map(blockText)).toContain(text);
};

step("{string} shows the image {string}", (ctx: SpaceWorld, page: string, name: string) =>
  expectBlock(ctx, page, `[image: ${name}]`),
);

step(
  "{string} says the image {string} is in the trash",
  (ctx: SpaceWorld, page: string, name: string) =>
    expectBlock(ctx, page, `[image: ${name} is in the trash]`),
);

step(
  "{string} says the image {string} was deleted",
  (ctx: SpaceWorld, page: string, name: string) =>
    expectBlock(ctx, page, `[image: ${name} was deleted]`),
);

step("the user moves the image {string} to the trash", async (ctx: SpaceWorld, name: string) => {
  await selectImage(ctx, name);
  await press(ctx, "d");
});

step("the user restores the image {string}", async (ctx: SpaceWorld, name: string) => {
  await selectImage(ctx, name);
  await press(ctx, "r");
});

step("the user deletes the image {string} for good", async (ctx: SpaceWorld, name: string) => {
  await selectImage(ctx, name);
  await press(ctx, "D");
  await choose(ctx, "Delete for good");
});

step("no slides remain in {string}", async (ctx: SpaceWorld, name: string) => {
  await openSpace(ctx, name);
  expect(mc(ctx).slides()).toEqual([]);
});

// After the last slide, so it lands at the end.
step("the user adds the slide {string} to {string}", async (ctx: SpaceWorld, title, deck) => {
  await openDeck(ctx, deck);
  const last = pane(ctx)
    .rows.filter((row) => row.kind === "slide")
    .at(-1);
  if (last) await selectRow(ctx, last.key);
  await press(ctx, "n");
  await answer(ctx, title);
});

step(
  "the user adds the slide {string} after {string} in {string}",
  async (ctx: SpaceWorld, title: string, after: string) => {
    await openSlide(ctx, after);
    await press(ctx, "n");
    await answer(ctx, title);
  },
);

step(
  "the user changes the slide {string} to {string} reading {string}",
  async (ctx: SpaceWorld, from: string, title: string, body: string) => {
    await openSlide(ctx, from);
    await press(ctx, "e");
    expect(findObject(ctx, "askInput").get("text")).toBe(from);
    await answer(ctx, title);
    await answer(ctx, body);
  },
);

step(
  "the slide {string} shows the line {string}",
  async (ctx: SpaceWorld, title: string, line: string) => {
    await openSlide(ctx, title);
    const shown = pane(ctx)
      .rows.filter((row) => row.kind === "slide" && !row.first)
      .map((row) => row.text.trim());
    expect(shown).toContain(line);
  },
);

step(
  "the user moves the slide {string} before {string}",
  async (ctx: SpaceWorld, title, before) => {
    await openSlide(ctx, title);
    await press(ctx, "m");
    await choose(ctx, `Before “${before}”`);
  },
);

step("the user deletes the slide {string}", async (ctx: SpaceWorld, title: string) => {
  await openSlide(ctx, title);
  await press(ctx, "d");
});

step("the second client sees the deck {string}", async (ctx: SpaceWorld, title: string) => {
  await ctx.second!.settled();
  expect(listed(secondPane(ctx).rows, "deck")).toContain(title);
});

step("the second client sees the slide {string}", async (ctx: SpaceWorld, title: string) => {
  await ctx.second!.settled();
  expect(slideTable(secondPane(ctx).rows).map((row) => row[0])).toContain(title);
});

// --- presenting ---

step("the user presents the deck {string}", async (ctx: SpaceWorld, title: string) => {
  await openDeck(ctx, title);
  await press(ctx, "p");
});

step(
  "the presenter shows {string}, slide {int} of {int}",
  async (ctx: SpaceWorld, title: string, number: number, count: number) => {
    await settle(ctx);
    expect(pane(ctx).view).toBe("present");
    expect(pane(ctx).title.endsWith(` · ${number} / ${count}`)).toBe(true);
    expect(pane(ctx).rows[0]!.text).toBe(title);
  },
);

step("the user steps forward", (ctx: SpaceWorld) => press(ctx, "Right"));
step("the user steps back", (ctx: SpaceWorld) => press(ctx, "Left"));
step("the user leaves the presenter", (ctx: SpaceWorld) => press(ctx, "Esc"));

step("nothing is being presented", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(pane(ctx).view).not.toBe("present");
});

step("the user is told the deck has no slides", async (ctx: SpaceWorld) => {
  await settle(ctx);
  expect(status(ctx).text).toBe("This deck has no slides to present.");
});

step("another client changes the slide {string} to {string}", async (ctx: SpaceWorld, from, to) => {
  mc(ctx).run("space.slide.update", {
    spaceId: currentSpaceId(ctx),
    slideId: mc(ctx).slideNamed(from).id,
    title: to,
  });
  await settle(ctx);
});

step("another client moves the slide {string} after {string}", async (ctx: SpaceWorld, a, b) => {
  mc(ctx).run("space.slide.move", {
    spaceId: currentSpaceId(ctx),
    slideId: mc(ctx).slideNamed(a).id,
    afterSlideId: mc(ctx).slideNamed(b).id,
  });
  await settle(ctx);
});

step("another client deletes the slide {string}", async (ctx: SpaceWorld, title: string) => {
  mc(ctx).run("space.slide.delete", {
    spaceId: currentSpaceId(ctx),
    slideId: mc(ctx).slideNamed(title).id,
  });
  await settle(ctx);
});

step("another client moves the deck {string} to the trash", async (ctx: SpaceWorld, title) => {
  mc(ctx).run("space.deck.trash", {
    spaceId: currentSpaceId(ctx),
    deckId: mc(ctx).deckNamed(title).id,
  });
  await settle(ctx);
});

step("the images list shows the prompt {string}", (ctx: SpaceWorld, prompt: string) => {
  expect(listed(pane(ctx).rows, "image").map((text) => text.split("  · ")[1])).toContain(prompt);
});

step("the user opens the page {string}", (ctx: SpaceWorld, title: string) => openPage(ctx, title));

step("the page shows the text {string}", (ctx: SpaceWorld, text: string) => {
  const rows = pane(ctx).rows.filter((row) => row.kind === "block" && row.first);
  expect(rows.map(blockText)).toContain(text);
});

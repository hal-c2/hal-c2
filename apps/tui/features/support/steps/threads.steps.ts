// Thread list, selection and thread lifecycle from the sidebar:
// features/tui/threads.feature and the @tui scenarios of features/threads/.
import { expect } from "bun:test";

import type { TuiNewThreadState, TuiSelectState } from "../../../src/host/composerState.ts";
import type { TuiOverlayState } from "../../../src/host/threadActions.ts";
import { step } from "../../steps.ts";
import { focusPanel } from "../gitWorld.ts";
import {
  addProject,
  addThread,
  change,
  env,
  flush,
  projectNamed,
  threadNamed,
  ui,
  type EnvThread,
} from "../environment.ts";
import {
  chooseCommand,
  chooseMenuItem,
  click,
  clickText,
  contextMenu,
  filterBy,
  findOnScreen,
  fromMenu,
  listedRow,
  listedTitles,
  openMenu,
  palette,
  rename,
  rightClick,
  rowPosition,
  runCommand,
  selectThread,
  sidebar,
  statusText,
  threadRows,
} from "../threadUi.ts";
import {
  advance,
  findObject,
  geometry,
  pressKey,
  resize,
  settle,
  snapshot,
  typeText,
  type World,
} from "../world.ts";

interface ThreadsWorld extends World {
  /** The thread a scenario is about when a step does not name it. */
  subject?: string;
  /** The list order a scenario captured to compare against. */
  order?: string[];
}

const HOUR_MS = 60 * 60_000;
const DAY_MS = 24 * HOUR_MS;
const iso = (ms: number) => new Date(ms).toISOString();
const now = (ctx: World) => ctx.nowMs!;
const statusKind = (ctx: World) => (ctx.host!.state.get("status") as { kind: string }).kind;
const overlay = (ctx: World) => ctx.host!.state.get("overlay") as TuiOverlayState;
const draft = (ctx: World) => ctx.host!.state.get("newThread") as TuiNewThreadState | null;
const callsTo = (ctx: World, method: string) =>
  ctx.fake!.calls.filter((call) => call.method === method);

function snoozeFields(ctx: World, untilMs = now(ctx) + DAY_MS): Partial<EnvThread> {
  return { snoozedUntil: iso(untilMs), snoozedAt: iso(now(ctx) - HOUR_MS) };
}
function settledFields(ctx: World, agoMs = HOUR_MS): Partial<EnvThread> {
  return { settledOverride: "settled", settledAt: iso(now(ctx) - agoMs) };
}

async function expectListed(ctx: World, title: string, listed = true): Promise<void> {
  await ui(ctx);
  if (listed) {
    expect(listedTitles(ctx)).toContain(title);
    expect(await snapshot(ctx)).toContain(title);
  } else {
    expect(listedTitles(ctx)).not.toContain(title);
  }
}

async function expectSection(ctx: World, title: string, section: string): Promise<void> {
  await ui(ctx);
  expect(listedRow(ctx, title)?.thread.section as string | undefined).toBe(section);
}

// --- Environments -----------------------------------------------------------

step("the terminal client is connected to an environment with several threads", (ctx: World) => {
  addProject(ctx, "shop");
  addProject(ctx, "docs");
  addThread(ctx, "Alpha", {
    project: "shop",
    branch: "feature/alpha",
    worktreePath: "/work/shop/.worktrees/alpha",
  });
  addThread(ctx, "Beta", { project: "shop", branch: "main" });
  addThread(ctx, "Gamma", { project: "shop" });
  addThread(ctx, "Fix login redirect", { project: "shop" });
  addThread(ctx, "Login docs", { project: "docs" });
  addThread(ctx, "Write guide", { project: "docs" });
});

step("a connected environment with the projects {string} and {string}", (ctx: World, a, b) => {
  addProject(ctx, a);
  addProject(ctx, b);
  addThread(ctx, `Tune ${a}`, { project: a });
  addThread(ctx, `Draft ${b}`, { project: b });
});

step(
  "a connected environment with the thread {string} on the branch {string} in the project {string}",
  (ctx: ThreadsWorld, title: string, branch: string, project: string) => {
    addThread(ctx, title, { project, branch });
    ctx.subject = title;
  },
);

step(
  "a connected environment with the idle thread {string} in the project {string}",
  (ctx: ThreadsWorld, title: string, project: string) => {
    addThread(ctx, title, { project });
    ctx.subject = title;
  },
);

step(
  "a connected environment with the thread {string} in the project {string}",
  (ctx: ThreadsWorld, title: string, project: string) => {
    addThread(ctx, title, { project });
    ctx.subject = title;
  },
);

step(
  "a connected environment with the threads {string} and {string} in the project {string}",
  (ctx: World, a: string, b: string, project: string) => {
    addThread(ctx, a, { project });
    addThread(ctx, b, { project });
  },
);

step("the project {string} has the thread {string}", (ctx: World, project: string, title) => {
  addThread(ctx, title, { project });
});

// --- Looking at the list ----------------------------------------------------

step("the user looks at the thread list", async (ctx: World) => {
  await ui(ctx);
});

step("the first snapshot arrives", async (ctx: World) => {
  await ui(ctx);
});

step("the first thread in the list is selected and open", async (ctx: World) => {
  const first = threadRows(ctx)[0]!;
  expect(first.selected).toBe(true);
  expect(sidebar(ctx).activeThreadKey).toBe(first.key);
  expect(ctx.host!.state.get("page")).toMatchObject({ kind: "thread", key: first.key });
});

step("the status line reports how many projects were loaded", async (ctx: World) => {
  const count = env(ctx).projects.length;
  expect(statusText(ctx)).toContain(`${count} project(s)`);
  expect(await snapshot(ctx)).toContain(`${count} project(s)`);
});

step(
  "threads were created in the order {string}, {string}, {string}",
  async (ctx: ThreadsWorld, a: string, b: string, c: string) => {
    const created = [a, b, c].map((title) => threadNamed(ctx, title).createdAt);
    expect(created).toEqual(created.toSorted());
    await ui(ctx);
    ctx.order = listedTitles(ctx);
  },
);

step("{string} receives a new message", async (ctx: World, title: string) => {
  await ui(ctx);
  change(ctx, () => {
    const thread = threadNamed(ctx, title);
    thread.latestUserMessageAt = iso(now(ctx));
    thread.updatedAt = iso(now(ctx));
    thread.session = { status: "running" };
  });
  await flush(ctx);
});

step("the thread list order does not change", (ctx: ThreadsWorld) => {
  expect(listedTitles(ctx)).toEqual(ctx.order!);
});

step("{string} was created before {string}", (ctx: World, first: string, second: string) => {
  addThread(ctx, first);
  addThread(ctx, second);
});

step("{string} is listed above {string}", async (ctx: World, upper: string, lower: string) => {
  const titles = listedTitles(ctx);
  expect(titles.indexOf(upper)).toBeGreaterThanOrEqual(0);
  expect(titles.indexOf(upper)).toBeLessThan(titles.indexOf(lower));
  const top = await findOnScreen(ctx, upper);
  const bottom = await findOnScreen(ctx, lower);
  expect(top!.y).toBeLessThan(bottom!.y);
});

// --- Shelves ----------------------------------------------------------------

step("active, snoozed and settled threads", (ctx: World) => {
  addThread(ctx, "Nap time", snoozeFields(ctx));
  addThread(ctx, "Shipped", settledFields(ctx));
});

step(
  "the list shows the active threads, then the snoozed shelf, then the settled shelf",
  async (ctx: World) => {
    await ui(ctx);
    const order = sidebar(ctx).rows.map((row) =>
      row.kind === "thread"
        ? row.thread.section
        : `${row.kind}:${"section" in row ? row.section : ""}`,
    );
    const firstShelf = order.indexOf("section:snoozed");
    expect(order.slice(0, firstShelf).every((entry) => entry === "active")).toBe(true);
    expect(firstShelf).toBeGreaterThan(0);
    expect(order.indexOf("section:settled")).toBeGreaterThan(firstShelf);
    const screen = await snapshot(ctx);
    expect(screen.indexOf("Gamma")).toBeLessThan(screen.indexOf("Snoozed"));
    expect(screen.indexOf("Snoozed")).toBeLessThan(screen.indexOf("Settled"));
  },
);

step(
  /^the (snoozed|settled) (?:shelf|section) is (collapsed|expanded)$/,
  async (ctx: World, section, wanted) => {
    // "Searching opens collapsed shelves" looks for the snoozed "cart" thread.
    const title = section === "snoozed" ? "Fix cart totals" : "Settled away";
    if (!env(ctx).threads.some((thread) => thread.title === title)) {
      addThread(ctx, title, section === "snoozed" ? snoozeFields(ctx) : settledFields(ctx));
    }
    await ui(ctx);
    const header = sidebar(ctx).rows.find(
      (row) => row.kind === "section" && row.section === section,
    );
    if (header?.kind === "section" && header.expanded !== (wanted === "expanded")) {
      ctx.host!.dispatch("sidebar.section.toggle", { section });
      await flush(ctx);
    }
  },
);

step("the selected thread is snoozed", async (ctx: ThreadsWorld) => {
  await selectThread(ctx, "Beta");
  change(ctx, () => Object.assign(threadNamed(ctx, "Beta"), snoozeFields(ctx)));
  await flush(ctx);
  ctx.subject = "Beta";
});

step("the selected thread is still shown in the list", async (ctx: ThreadsWorld) => {
  const row = listedRow(ctx, ctx.subject!);
  expect(row?.selected).toBe(true);
  expect(await snapshot(ctx)).toContain(ctx.subject!);
});

step(/^the user (collapses|expands) the settled section$/, async (ctx: World, verb: string) => {
  await ui(ctx);
  await clickText(ctx, verb === "collapses" ? "▾ Settled" : "▸ Settled");
});

step("its threads are hidden", async (ctx: World) => {
  const screen = await snapshot(ctx);
  expect(screen).not.toContain("Settled away");
});

step("the section shows how many threads it holds", async (ctx: World) => {
  const count = env(ctx).threads.filter((thread) => thread.settledOverride === "settled").length;
  expect(await snapshot(ctx)).toContain(`Settled (${count})`);
});

step("its threads are shown again", async (ctx: World) => {
  expect(await snapshot(ctx)).toContain("Settled away");
});

step("the user has selected a settled thread", async (ctx: ThreadsWorld) => {
  addThread(ctx, "Settled away", settledFields(ctx));
  addThread(ctx, "Settled picked", settledFields(ctx, 2 * HOUR_MS));
  await selectThread(ctx, "Settled picked");
  ctx.subject = "Settled picked";
});

step("the selected thread is still shown", async (ctx: ThreadsWorld) => {
  expect(await snapshot(ctx)).not.toContain("Settled away");
  const row = listedRow(ctx, ctx.subject!);
  expect(row?.selected).toBe(true);
  expect(await snapshot(ctx)).toContain(ctx.subject!);
});

function addSettled(ctx: World, count: number): void {
  for (let i = 1; i <= count; i += 1) {
    const title = `Settled ${String(i).padStart(2, "0")}`;
    addThread(ctx, title, settledFields(ctx, i * HOUR_MS));
  }
}

step("there are {int} settled threads", (ctx: World, count: number) => addSettled(ctx, count));
step("more settled threads than the shelf shows at first", (ctx: World) => addSettled(ctx, 15));

step("the user looks at the settled section", async (ctx: World) => {
  await ui(ctx);
});

step("the first {int} settled threads are shown", async (ctx: World, count: number) => {
  const settled = threadRows(ctx).filter((row) => row.thread.section === "settled");
  expect(settled.map((row) => row.thread.title)).toEqual(
    Array.from({ length: count }, (_, i) => `Settled ${String(i + 1).padStart(2, "0")}`),
  );
  expect(await snapshot(ctx)).not.toContain(`Settled ${String(count + 1).padStart(2, "0")}`);
});

step("the user can show more", async (ctx: World) => {
  const total = env(ctx).threads.filter((thread) => thread.settledOverride === "settled").length;
  await clickText(ctx, "Show ");
  expect(threadRows(ctx).filter((row) => row.thread.section === "settled")).toHaveLength(total);
});

step("the user selects a settled thread beyond the first page", async (ctx: ThreadsWorld) => {
  // Find it with the filter, then clear the filter: the selection stays.
  await filterBy(ctx, "Settled 13");
  expect(sidebar(ctx).activeThreadKey).toBe(listedRow(ctx, "Settled 13")!.key);
  await pressKey(ctx, "Esc");
  await flush(ctx);
  ctx.subject = "Settled 13";
});

step("the shelf shows enough pages to keep that thread visible", async (ctx: ThreadsWorld) => {
  expect(sidebar(ctx).filter).toBe("");
  expect(listedRow(ctx, ctx.subject!)?.selected).toBe(true);
  expect(await snapshot(ctx)).toContain(ctx.subject!);
});

step("a thread snoozed until 10:00", (ctx: ThreadsWorld) => {
  const wake = new Date(ctx.nowMs!);
  wake.setHours(10, 0, 0, 0);
  ctx.nowMs = wake.getTime() - 60_000;
  addThread(ctx, "Wake me", snoozeFields(ctx, wake.getTime()));
  ctx.subject = "Wake me";
});

step("the clock reaches 10:00", async (ctx: ThreadsWorld) => {
  await ui(ctx);
  // Still asleep (the snoozed shelf starts collapsed, so it may be unlisted).
  expect(listedRow(ctx, ctx.subject!)?.thread.section).not.toBe("active");
  ctx.nowMs = ctx.nowMs! + 60_000;
  await advance(ctx, 60_000);
  await flush(ctx);
});

step(
  "the thread moves to the active threads without the user doing anything",
  async (ctx: ThreadsWorld) => {
    await expectSection(ctx, ctx.subject!, "active");
    expect(ctx.fake!.calls).toEqual([]);
  },
);

// --- Scope and filter -------------------------------------------------------

step(
  /^the user scopes the thread list to (?:the project )?"([^"]*)"$/,
  async (ctx: World, project) => {
    await runCommand(ctx, `Show project ${project}`);
  },
);

step("the thread list is scoped to {string}", async (ctx: World, project: string) => {
  await runCommand(ctx, `Show project ${project}`);
});

step("the user scopes the thread list to all projects", async (ctx: World) => {
  await runCommand(ctx, "Show all projects");
});

async function expectOnlyFrom(ctx: World, project: string, match = ""): Promise<void> {
  const projectId = projectNamed(ctx, project).id;
  const expected = env(ctx)
    .threads.filter(
      (thread) =>
        thread.projectId === projectId && thread.title.toLowerCase().includes(match.toLowerCase()),
    )
    .map((thread) => thread.title);
  expect(expected.length).toBeGreaterThan(0);
  expect(listedTitles(ctx).toSorted()).toEqual(expected.toSorted());
  const screen = await snapshot(ctx);
  expect(screen).toContain(`Threads · ${project}`);
  for (const other of env(ctx).threads.filter((thread) => !expected.includes(thread.title))) {
    expect(screen).not.toContain(other.title);
  }
}

step(/^only threads (?:in|from) "([^"]*)" are listed$/, (ctx: World, project) =>
  expectOnlyFrom(ctx, project),
);

step(
  "only threads in {string} whose title matches {string} are listed",
  (ctx: World, project: string, query: string) => expectOnlyFrom(ctx, project, query),
);

step("threads from {string} and {string} are listed", async (ctx: World, a: string, b: string) => {
  const projects = new Set(threadRows(ctx).map((row) => row.thread.projectName));
  expect([...projects].toSorted()).toEqual([a, b].toSorted());
  expect(sidebar(ctx).scopeProjectKey).toBeNull();
});

step(
  /^the user (?:filters|is filtering) (?:the thread list|the list|threads) by "([^"]*)"$/,
  (ctx: World, query) => filterBy(ctx, query),
);

step("the thread list is filtered by {string}", async (ctx: World, query: string) => {
  await filterBy(ctx, query);
  await pressKey(ctx, "Enter");
});

step("the user clears the filter", async (ctx: World) => {
  await pressKey(ctx, "Ctrl+F");
  await pressKey(ctx, "Esc");
  await flush(ctx);
});

step("the search shows the active query", async (ctx: World) => {
  expect(findObject(ctx, "sidebarFilter").get("text")).toBe(sidebar(ctx).filter);
  expect(await snapshot(ctx)).toContain(sidebar(ctx).filter);
});

step("the filter is cleared and every thread is listed again", async (ctx: World) => {
  expect(sidebar(ctx).filter).toBe("");
  expect(findObject(ctx, "sidebarFilter").get("text")).toBe("");
  expect(listedTitles(ctx).toSorted()).toEqual(
    env(ctx)
      .threads.map((t) => t.title)
      .toSorted(),
  );
});

step("only {string} is listed", async (ctx: World, title: string) => {
  expect(listedTitles(ctx)).toEqual([title]);
});

step("{string} is listed", (ctx: World, title: string) => expectListed(ctx, title));

step("{string} and {string} are listed", async (ctx: World, a: string, b: string) => {
  await expectListed(ctx, a);
  await expectListed(ctx, b);
});

step("matching snoozed threads are shown", async (ctx: World) => {
  expect(listedRow(ctx, "Fix cart totals")?.thread.section).toBe("snoozed");
  expect(await snapshot(ctx)).toContain("Fix cart totals");
});

// The snoozed thread "Searching opens collapsed shelves" looks for.
step("the snoozed section holds {string}", (ctx: World, title: string) => {
  addThread(ctx, title, snoozeFields(ctx));
});

// --- Selection --------------------------------------------------------------

step("the thread {string} is selected", (ctx: World, title: string) => selectThread(ctx, title));

step("{string} is selected", (ctx: World, title: string) => {
  expect(sidebar(ctx).activeThreadKey).toBe(listedRow(ctx, title)!.key);
});

step("more threads than fit on screen", (ctx: World) => {
  for (let i = 1; i <= 50; i += 1) addThread(ctx, `Backlog ${String(i).padStart(2, "0")}`);
});

step("the user moves to the next thread past the bottom edge", async (ctx: World) => {
  await ui(ctx);
  const visible = sidebar(ctx).visibleRows.length;
  const firstSelected = threadRows(ctx).findIndex((row) => row.selected);
  for (let i = firstSelected; i < visible; i += 1) await pressKey(ctx, "Alt+Down");
  await flush(ctx);
});

step("the list scrolls to keep the selected thread in view", async (ctx: World) => {
  const state = sidebar(ctx);
  expect(state.scrollTop).toBeGreaterThan(0);
  const selected = state.visibleRows.findIndex((row) => "selected" in row && row.selected);
  expect(selected).toBe(state.visibleRows.length - 1);
  const title = (state.visibleRows[selected] as { thread: { title: string } }).thread.title;
  const { y } = rowPosition(ctx, title);
  expect((await snapshot(ctx)).split("\n")[y]).toContain(title);
});

step("the first project is expanded", async (ctx: World) => {
  // The list is flat: every project's threads are already listed.
  await ui(ctx);
  expect(sidebar(ctx).rows.some((row) => row.kind === "section")).toBe(false);
});

step("the second visible thread is selected", (ctx: World) => {
  const second = threadRows(ctx, sidebar(ctx).visibleRows)[1]!;
  expect(second.selected).toBe(true);
  expect(sidebar(ctx).activeThreadKey).toBe(second.key);
});

// --- Context menu -----------------------------------------------------------

const CONDITIONS: Record<string, (ctx: World) => Partial<EnvThread> | void> = {
  "has no workspace folder": (ctx) => {
    // A project the client knows no folder for.
    addProject(ctx, "scratch").workspaceRoot = "";
    return {};
  },
  "has a workspace folder": () => ({ worktreePath: "/work/shop/.worktrees/target" }),
  "has no branch": () => ({ branch: null }),
  'is on the branch "fix/login"': () => ({ branch: "fix/login" }),
  "is running a turn": () => ({ session: { status: "running" } }),
  "is idle": () => ({ session: null }),
  "is on a server without settlement": (ctx) => {
    env(ctx).settlement = false;
  },
};

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");

step(
  new RegExp(`^a thread that (${Object.keys(CONDITIONS).map(escapeRegExp).join("|")})$`),
  (ctx: ThreadsWorld, condition: string) => {
    const apply = CONDITIONS[condition]!;
    const fields = apply(ctx) ?? {};
    addThread(ctx, "Target", {
      ...(condition === "has no workspace folder" ? { project: "scratch" } : {}),
      ...fields,
    });
    ctx.subject = "Target";
  },
);

step(/^the user opens (?:its context menu|the thread's menu)$/, async (ctx: ThreadsWorld) => {
  await openMenu(ctx, ctx.subject!);
});

step("the user opens the menu for {string}", async (ctx: World, title: string) => {
  await openMenu(ctx, title);
});

// keymap.feature: the menu's keys, on a thread with or without a workspace folder.
async function openTargetMenu(ctx: ThreadsWorld, workspace: boolean): Promise<void> {
  if (!workspace) addProject(ctx, "scratch").workspaceRoot = "";
  addThread(ctx, "Target", workspace ? {} : { project: "scratch" });
  ctx.subject = "Target";
  await openMenu(ctx, "Target");
  expect(ctx.host!.state.get("mode")).toBe("contextMenu");
}
step("the thread context menu is open", (ctx: ThreadsWorld) => openTargetMenu(ctx, true));
step("the thread context menu is open for a thread with no workspace", (ctx: ThreadsWorld) =>
  openTargetMenu(ctx, false),
);

const highlighted = (ctx: World) => {
  const menu = contextMenu(ctx)!;
  const row = menu.rows.find((candidate) => candidate.kind === "item" && candidate.selected);
  expect(row && row.kind === "item" ? row.label : null).toBe(menu.items[menu.selectedIndex]!.label);
  return menu.items[menu.selectedIndex]!.label;
};

// The menu opens on "Settle thread": the next enabled item is "Rename thread",
// and the previous one wraps to "Delete" at the bottom.
step(/^the (next|previous) enabled item is highlighted$/, async (ctx: World, which: string) => {
  await flush(ctx);
  expect(highlighted(ctx)).toBe(which === "next" ? "Rename thread" : "Delete");
});

step(
  "the user moves down past the last item",
  async (ctx: ThreadsWorld & { highlights?: string[] }) => {
    const last = contextMenu(ctx)!.items.length - 1;
    ctx.highlights = [highlighted(ctx)];
    for (let guard = 0; guard <= last && contextMenu(ctx)!.selectedIndex !== last; guard += 1) {
      await pressKey(ctx, "Down");
      ctx.highlights.push(highlighted(ctx));
    }
    expect(contextMenu(ctx)!.selectedIndex).toBe(last);
    await pressKey(ctx, "Down");
    ctx.highlights.push(highlighted(ctx));
  },
);

step("the highlight wraps to the first item", (ctx: World) => {
  expect(contextMenu(ctx)!.selectedIndex).toBe(0);
  expect(highlighted(ctx)).toBe(contextMenu(ctx)!.items[0]!.label);
});

step(
  "{string} is never highlighted",
  (ctx: ThreadsWorld & { highlights?: string[] }, label: string) => {
    expect(contextMenu(ctx)!.items.map((item) => item.label)).toContain(label);
    expect(ctx.highlights).toContain("Delete");
    expect(ctx.highlights).not.toContain(label);
  },
);

step(/^"([^"]*)" is (enabled|disabled|absent)$/, async (ctx: World, label, availability) => {
  const item = contextMenu(ctx)!.items.find((candidate) => candidate.label === label);
  const screen = await snapshot(ctx);
  if (availability === "absent") {
    expect(item).toBeUndefined();
    expect(screen).not.toContain(label);
    return;
  }
  expect(item).toBeDefined();
  expect(item!.disabled === true).toBe(availability === "disabled");
  expect(screen).toContain(label);
});

step("a thread near the bottom right of the terminal", async (ctx: ThreadsWorld) => {
  for (let i = 1; i <= 40; i += 1) addThread(ctx, `Filler ${String(i).padStart(2, "0")}`);
  await resize(ctx, 70, 30);
  await ui(ctx);
  // On a narrow terminal the list opens across the whole width.
  await pressKey(ctx, "Ctrl+F");
  const rows = sidebar(ctx).visibleRows;
  const last = rows[rows.length - 1]!;
  if (last.kind !== "thread") throw new Error("the last row on screen is not a thread");
  ctx.subject = last.thread.title;
});

step("the user opens its context menu at the bottom right", async (ctx: ThreadsWorld) => {
  const { y } = rowPosition(ctx, ctx.subject!);
  await rightClick(ctx, { x: ctx.columns! - 2, y });
});

step("the whole menu is drawn inside the terminal", async (ctx: World) => {
  const menu = contextMenu(ctx)!;
  expect(menu).not.toBeNull();
  expect(menu.x).toBeGreaterThanOrEqual(0);
  expect(menu.y).toBeGreaterThanOrEqual(0);
  expect(menu.x + menu.width).toBeLessThanOrEqual(ctx.columns!);
  expect(menu.y + menu.height).toBeLessThanOrEqual(ctx.rows!);
  const box = geometry(findObject(ctx, "contextMenu"));
  expect(box).toMatchObject({ visible: true, width: menu.width, height: menu.height });
  const screen = (await snapshot(ctx)).split("\n");
  expect(screen.findIndex((line) => line.includes("Delete"))).toBe(menu.y + menu.height - 2);
});

step("the user long-presses {string}", async (ctx: World, title: string) => {
  await ui(ctx);
  const at = rowPosition(ctx, title);
  await ctx.app!.mockMouse.pressDown(at.x, at.y);
  await ctx.app!.renderOnce();
  await advance(ctx, 500);
  await ctx.app!.mockMouse.release(at.x, at.y);
  await flush(ctx);
});

step(
  /^the (?:menu for|actions for) "([^"]*)" (?:opens|are offered)$/,
  async (ctx: World, title) => {
    const menu = contextMenu(ctx);
    expect(menu?.threadKey).toBe(listedRow(ctx, title)!.key);
    const screen = await snapshot(ctx);
    for (const label of [
      "Rename thread",
      "Copy path",
      "Copy thread ID",
      "Archive thread",
      "Delete",
    ]) {
      expect(menu!.items.map((item) => item.label)).toContain(label);
      expect(screen).toContain(label);
    }
  },
);

step("{string} has no workspace path", (ctx: World, title: string) => {
  const thread = threadNamed(ctx, title);
  thread.worktreePath = null;
  env(ctx).projects.find((project) => project.id === thread.projectId)!.workspaceRoot = "";
});

step("copying the path is unavailable", (ctx: World) => {
  expect(contextMenu(ctx)!.items.find((item) => item.label === "Copy path")?.disabled).toBe(true);
});

step(/^archiving is unavailable$/, (ctx: World) => {
  expect(contextMenu(ctx)!.items.find((item) => item.id === "archive")?.disabled).toBe(true);
});

// --- Copy -------------------------------------------------------------------

step("the user chooses {string} for a thread", async (ctx: ThreadsWorld, item: string) => {
  ctx.subject = "Alpha";
  await fromMenu(ctx, "Alpha", item);
});

const COPY_ITEMS: Record<string, string> = {
  path: "Copy path",
  branch: "Copy branch",
  "thread id": "Copy thread ID",
};

step(
  /^the user copies the (path|branch|thread id) of "([^"]*)"$/,
  async (ctx: ThreadsWorld, detail, title) => {
    ctx.subject = title;
    await fromMenu(ctx, title, COPY_ITEMS[detail]!);
  },
);

function workspaceOf(ctx: World, thread: EnvThread): string {
  return (
    thread.worktreePath ??
    env(ctx).projects.find((project) => project.id === thread.projectId)!.workspaceRoot
  );
}

async function expectClipboard(ctx: World, value: string): Promise<void> {
  expect(ctx.clipboard!.at(-1)).toBe(value);
  expect(statusKind(ctx)).toBe("success");
}

step(
  /^the clipboard holds the thread's (workspace folder|workspace path|branch name|thread id)$/,
  (ctx: ThreadsWorld, fact: string) => {
    const thread = threadNamed(ctx, ctx.subject!);
    const value =
      fact === "branch name"
        ? thread.branch!
        : fact === "thread id"
          ? thread.id
          : workspaceOf(ctx, thread);
    return expectClipboard(ctx, value);
  },
);

step("the clipboard holds the id of {string}", (ctx: World, title: string) =>
  expectClipboard(ctx, threadNamed(ctx, title).id),
);

step("the clipboard holds {string}", (ctx: World, value: string) => expectClipboard(ctx, value));

// --- Rename -----------------------------------------------------------------

step(/^the user renames (?:the thread )?"([^"]*)" to "([^"]*)"$/, (ctx: World, title, next) =>
  rename(ctx, title, next),
);

step("the user renames {string} to an empty title", (ctx: World, title: string) =>
  rename(ctx, title, ""),
);

step("the thread is listed as {string}", async (ctx: World, title: string) => {
  await expectListed(ctx, title);
});

step("every connected client shows the new title", (ctx: ThreadsWorld) => {
  const [call] = callsTo(ctx, "renameThread");
  expect(call).toBeDefined();
  // The environment holds the new title, so every client's snapshot carries it.
  const renamed = env(ctx).threads.find((thread) => thread.id === call!.args[0]);
  expect(renamed?.title).toBe(call!.args[1] as string);
});

step("the user is renaming the thread {string}", async (ctx: World, title: string) => {
  await fromMenu(ctx, title, "Rename thread");
  expect(overlay(ctx)).toMatchObject({ kind: "rename", title });
  expect(findObject(ctx, "renameInput").get("text")).toBe(title);
});

step(/^the (?:thread is still called|title stays) "([^"]*)"$/, async (ctx: World, title) => {
  expect(overlay(ctx)).toBeNull();
  expect(callsTo(ctx, "renameThread")).toEqual([]);
  await expectListed(ctx, title);
});

// --- Settle -----------------------------------------------------------------

step("the server supports settling threads", (ctx: World) => {
  env(ctx).settlement = true;
});

step(/^the user settles (?:the thread )?"([^"]*)"$/, (ctx: World, title) =>
  fromMenu(ctx, title, "Settle thread"),
);

step("the user un-settles {string}", (ctx: World, title: string) =>
  fromMenu(ctx, title, "Un-settle thread"),
);

step("the user settles {string} from the command palette", async (ctx: World, title: string) => {
  await selectThread(ctx, title);
  await runCommand(ctx, "Settle thread");
});

step(/^(?:the thread )?"([^"]*)" is settled$/, (ctx: World, title) => {
  Object.assign(threadNamed(ctx, title), settledFields(ctx));
});

step(/^"([^"]*)" moves to the settled (?:shelf|section)$/, async (ctx: World, title) => {
  expect(callsTo(ctx, "settleThread")).toHaveLength(1);
  await expectSection(ctx, title, "settled");
});

step(/^"([^"]*)" returns to (?:the top of )?the active threads$/, async (ctx: World, title) => {
  await expectSection(ctx, title, "active");
  expect(callsTo(ctx, "unsettleThread")).toHaveLength(1);
  expect(threadRows(ctx)[0]?.thread.title).toBe(
    threadRows(ctx).find((row) => row.thread.section === "active")!.thread.title,
  );
});

step("the thread {string} is waiting on an approval", (ctx: World, title: string) => {
  threadNamed(ctx, title).hasPendingApprovals = true;
});

step("the environment rejects the settle", (ctx: World) => {
  env(ctx).settleError = "Thread has unfinished work";
});

step("{string} stays active", async (ctx: World, title: string) => {
  await expectSection(ctx, title, "active");
});

step("the status line shows the server's reason as an error", (ctx: World) => {
  expect(statusKind(ctx)).toBe("error");
  expect(statusText(ctx)).toContain("Thread needs attention before it can be settled");
});

step("the status line reports that the settle failed and why", async (ctx: World) => {
  expect(statusKind(ctx)).toBe("error");
  expect(statusText(ctx)).toBe("Settle failed: Thread has unfinished work");
  expect(await snapshot(ctx)).toContain("Settle failed");
});

step("{string} is linked to a pull request", (ctx: World, title: string) => {
  threadNamed(ctx, title).linkedPullRequest = {
    number: 42,
    url: "https://github.com/acme/shop/pull/42",
    state: "open",
  };
});

step("the pull request is merged on GitHub", async (ctx: ThreadsWorld) => {
  await ui(ctx);
  // The server projects auto-settle into the snapshot.
  change(ctx, () => Object.assign(threadNamed(ctx, ctx.subject!), settledFields(ctx, 0)));
  await flush(ctx);
});

step(
  "{string} moves to the settled section without the user settling it",
  async (ctx: World, title: string) => {
    await expectSection(ctx, title, "settled");
    expect(callsTo(ctx, "settleThread")).toEqual([]);
  },
);

// --- Archive ----------------------------------------------------------------

step(/^the user archives (?:the open thread )?"([^"]*)"$/, async (ctx: World, title) => {
  await selectThread(ctx, title);
  await fromMenu(ctx, title, "Archive thread");
});

step(
  /^(?:the user archived the open thread "([^"]*)" and it is still open|"([^"]*)" is archived)$/,
  async (ctx: World, a?: string, b?: string) => {
    const title = (a ?? b)!;
    await selectThread(ctx, title);
    await fromMenu(ctx, title, "Archive thread");
    expect(listedRow(ctx, title)).toBeUndefined();
    expect(ctx.host!.state.get("page")).toMatchObject({ kind: "thread", title });
  },
);

step(/^the user unarchives (?:it from the command palette|"([^"]*)")$/, (ctx: World) =>
  runCommand(ctx, "Unarchive thread"),
);

step(
  /^"([^"]*)" (?:leaves the thread list|is no longer in the thread list)$/,
  async (ctx: World, title) => {
    await expectListed(ctx, title, false);
    expect(env(ctx).threads.find((thread) => thread.title === title)?.archivedAt).not.toBeNull();
  },
);

step(/^"([^"]*)" (?:returns to the thread list|is back in the thread list)$/, (ctx: World, title) =>
  expectListed(ctx, title),
);

// --- Delete -----------------------------------------------------------------

step(/^the user deletes (?:the thread )?"([^"]*)"$/, (ctx: World, title) =>
  fromMenu(ctx, title, "Delete"),
);

step(
  /^the (?:client is asking|user was asked) to confirm deleting "([^"]*)"$/,
  async (ctx: World, title) => {
    await fromMenu(ctx, title, "Delete");
    expect(overlay(ctx)).toMatchObject({ kind: "confirmDelete", title });
  },
);

step(
  "the client warns and asks to confirm with {string} or {string}",
  async (ctx: World, yes, no) => {
    expect(overlay(ctx)?.kind).toBe("confirmDelete");
    const screen = await snapshot(ctx);
    expect(screen).toContain("this can't be undone");
    expect(screen).toContain(`${yes} delete · ${no} / Esc cancel`);
  },
);

step("the user is warned that this can't be undone", async (ctx: World) => {
  expect(overlay(ctx)?.kind).toBe("confirmDelete");
  expect(await snapshot(ctx)).toContain("this can't be undone");
});

step("{string} is kept until the user confirms", async (ctx: World, title: string) => {
  expect(callsTo(ctx, "deleteThread")).toEqual([]);
  await expectListed(ctx, title);
});

step("the user confirms", async (ctx: World) => {
  await pressKey(ctx, "y");
  await flush(ctx);
});

step("the user cancels", async (ctx: World) => {
  await pressKey(ctx, "Esc");
  await flush(ctx);
});

step(/^"([^"]*)" is deleted(?: and leaves the list)?$/, async (ctx: World, title) => {
  expect(callsTo(ctx, "deleteThread")).toHaveLength(1);
  expect(env(ctx).threads.some((thread) => thread.title === title)).toBe(false);
  await expectListed(ctx, title, false);
  expect(statusText(ctx)).toBe("Deleted.");
});

step(/^"([^"]*)" is still (?:listed|in the thread list)$/, async (ctx: World, title) => {
  await flush(ctx);
  expect(overlay(ctx)).toBeNull();
  expect(callsTo(ctx, "deleteThread")).toEqual([]);
  await expectListed(ctx, title);
});

// --- Stop -------------------------------------------------------------------

step("the open thread is running a turn", async (ctx: ThreadsWorld) => {
  threadNamed(ctx, "Alpha").session = { status: "running" };
  await selectThread(ctx, "Alpha");
  expect(listedRow(ctx, "Alpha")?.thread.statusLabel).toBe("Working");
  ctx.subject = "Alpha";
});

step("the user stops the session from the command palette", (ctx: World) =>
  runCommand(ctx, "Stop session"),
);

// A thread from the list (the palette's "Stop session"): its session stops.
// Otherwise (Esc twice in the composer): the open thread's turn is interrupted.
step("the turn stops", async (ctx: ThreadsWorld) => {
  if (ctx.subject === undefined) {
    await settle(ctx);
    const page = ctx.host!.state.get("page") as { threadId: string | null };
    const interrupted = callsTo(ctx, "interrupt").map((call) => String(call.args[0]));
    expect(interrupted).toEqual([String(page.threadId)]);
    return;
  }
  const thread = threadNamed(ctx, ctx.subject!);
  expect(callsTo(ctx, "stopSession").map((call) => call.args[0])).toEqual([thread.id]);
  expect(listedRow(ctx, ctx.subject!)?.thread.statusLabel).not.toBe("Working");
});

// --- Palette ----------------------------------------------------------------

async function openPalette(ctx: World) {
  await ui(ctx);
  await pressKey(ctx, "Ctrl+K");
  expect(palette(ctx).open).toBe(true);
  expect(geometry(findObject(ctx, "commandPalette")).visible).toBe(true);
}
// Given: open it. Then: it is open, drawn, and keys go to it.
step("the command palette is open", async (ctx: World) => {
  if (ctx.stepType !== "Outcome") return openPalette(ctx);
  await settle(ctx);
  expect(palette(ctx).open).toBe(true);
  expect(ctx.host!.state.get("mode")).toBe("command");
  expect(geometry(findObject(ctx, "commandPalette")).visible).toBe(true);
});
step("the user opens the command palette", openPalette);

step(
  /^"([^"]*)" is listed (first|as a fuzzy subsequence match|through its keywords)$/,
  async (ctx: World, command, rank) => {
    const titles = palette(ctx).commands.map((item) => item.title);
    if (rank === "first") expect(titles[0]).toBe(command);
    else expect(titles).toContain(command);
    if (rank === "through its keywords") {
      expect(command.toLowerCase()).not.toContain(palette(ctx).query.toLowerCase());
    }
    expect(await snapshot(ctx)).toContain(command);
  },
);

// In an open picker (model, access, effort): among its options; otherwise a palette command.
step("{string} is offered", async (ctx: World, label: string) => {
  const picker = ctx.host!.state.get("select") as TuiSelectState;
  if (picker.open) {
    await settle(ctx);
    const options = (ctx.host!.state.get("select") as TuiSelectState).options;
    expect(options.map((option) => option.label)).toContain(label);
  } else {
    expect(palette(ctx).commands.map((item) => item.title)).toContain(label);
  }
  expect(await snapshot(ctx)).toContain(label);
});

step("the user chooses {string} from the command palette", chooseCommand);

step("the palette shows that there are no matching commands", async (ctx: World) => {
  expect(palette(ctx).commands).toEqual([]);
  expect(await snapshot(ctx)).toContain("No matching commands");
});

// --- Status -----------------------------------------------------------------

const STATES: Record<string, Partial<EnvThread>> = {
  "is waiting for an approval": { hasPendingApprovals: true },
  "is waiting for an answer to a question": { hasPendingUserInput: true },
  "has a plan ready to review": { hasActionableProposedPlan: true },
  "has an agent working": { session: { status: "running" } },
  "is starting its agent session": { session: { status: "starting" } },
  "had its last run fail": { session: { status: "error" } },
  "finished work the user has not seen": { session: { status: "stopped" } },
};

step(
  new RegExp(`^"([^"]*)" (${Object.keys(STATES).join("|")})$`),
  (ctx: World, title: string, state: string) => {
    Object.assign(threadNamed(ctx, title), STATES[state]);
  },
);

step("the agent is working in {string}", (ctx: ThreadsWorld, title: string) => {
  threadNamed(ctx, title).session = { status: "running" };
  ctx.subject = title;
});

step("the row for {string} reads {string}", async (ctx: World, title: string, label: string) => {
  expect(listedRow(ctx, title)?.thread.statusLabel).toBe(label);
  const { y } = rowPosition(ctx, title);
  expect((await snapshot(ctx)).split("\n")[y]).toContain(label);
});

// --- New thread -------------------------------------------------------------

step("the user is looking at a thread in {string}", async (ctx: ThreadsWorld, project: string) => {
  // In a git world (source-control features) the thread is its checkout's; look at its panel.
  if ((ctx as World & { scm?: unknown }).scm) return focusPanel(ctx);
  // This environment starts new threads in a new worktree unless told otherwise.
  env(ctx).defaultThreadEnvMode = "worktree";
  addThread(ctx, "Current work", { project, branch: "main" });
  ctx.subject = "Current work";
});

step("the user starts a new thread", async (ctx: World) => {
  await ui(ctx);
  await pressKey(ctx, "Ctrl+N");
  await flush(ctx);
});

step("the user opens the new thread form", async (ctx: World) => {
  await ui(ctx);
  await pressKey(ctx, "Ctrl+N");
  await flush(ctx);
});

step("a draft thread opens in {string}", async (ctx: World, project: string) => {
  await ctx.host!.settled();
  await flush(ctx);
  expect(ctx.host!.state.get("page")).toMatchObject({ kind: "draft", projectTitle: project });
  expect(draft(ctx)?.projectName).toBe(project);
  expect(await snapshot(ctx)).toContain(`New thread · ${project}`);
});

step("the draft is listed at the top of the thread list", async (ctx: World) => {
  const [first] = sidebar(ctx).rows;
  expect(first?.kind).toBe("draft");
  expect(sidebar(ctx).activeDraftId).toBe(draft(ctx)!.draftId);
  expect((await snapshot(ctx)).split("\n")[2]).toContain("+ New thread");
});

step("the current thread is on the branch {string}", (ctx: ThreadsWorld, branch: string) => {
  threadNamed(ctx, ctx.subject!).branch = branch;
});

step("a new worktree is preselected", async (ctx: World) => {
  expect(draft(ctx)?.workspaceMode).toBe("new-worktree");
  expect(await snapshot(ctx)).toContain("New worktree ▾");
});

step("{string} is offered as the base branch", async (ctx: World, branch: string) => {
  expect(draft(ctx)?.branch).toBe(branch);
  expect(await snapshot(ctx)).toContain(`branch ${branch} ▾`);
});

const worktreeFor = (branch: string) => `/work/shop/.worktrees/${branch.replace(/\//g, "-")}`;

step("the selected thread works in the worktree for {string}", (ctx: ThreadsWorld, branch) => {
  Object.assign(threadNamed(ctx, ctx.subject!), { branch, worktreePath: worktreeFor(branch) });
  env(ctx).refs.push({
    name: branch,
    current: false,
    isDefault: false,
    worktreePath: worktreeFor(branch),
  } as never);
});

step("the form targets the worktree for {string}", async (ctx: World, branch: string) => {
  expect(draft(ctx)).toMatchObject({
    workspaceMode: "current",
    branch,
    worktreePath: worktreeFor(branch),
  });
  const screen = await snapshot(ctx);
  expect(screen).toContain("Current worktree ▾");
  expect(screen).toContain(`branch ${branch} ▾`);
});

step("the branch {string} already has a worktree", (ctx: World, branch: string) => {
  env(ctx).refs.push({
    name: branch,
    current: false,
    isDefault: false,
    worktreePath: worktreeFor(branch),
  } as never);
});

step("the branch {string} exists but is not checked out", (ctx: World, branch: string) => {
  env(ctx).refs.push({
    name: branch,
    current: false,
    isDefault: false,
    worktreePath: null,
  } as never);
});

async function startThreadOn(ctx: World, branch: string): Promise<void> {
  await ui(ctx);
  await pressKey(ctx, "Ctrl+N");
  await flush(ctx);
  // Work in the current checkout (the project root here), on that branch,
  // picked from the workspace and branch under the composer.
  await click(ctx, await positionOf(ctx, "composerWorkspace"));
  await clickText(ctx, "Current checkout");
  await click(ctx, await positionOf(ctx, "composerBranch"));
  await clickText(ctx, `  ${branch}`);
  expect(draft(ctx)?.branch).toBe(branch);
  await typeText(ctx, `Continue on ${branch}`);
  await pressKey(ctx, "Enter");
  await flush(ctx);
}

async function positionOf(ctx: World, objectName: string): Promise<{ x: number; y: number }> {
  const text = String(findObject(ctx, objectName).get("text")).trim();
  const at = await findOnScreen(ctx, text);
  if (!at) throw new Error(`${objectName} ("${text}") is not on screen`);
  return { x: at.x + 1, y: at.y };
}

step(/^the user starts a new thread (?:in the project root )?on "([^"]*)"$/, (ctx: World, branch) =>
  startThreadOn(ctx, branch),
);

step("the thread works in the existing worktree for {string}", (ctx: World, branch: string) => {
  const [call] = callsTo(ctx, "createThread");
  expect(call?.args[0]).toMatchObject({ branch, worktreePath: worktreeFor(branch) });
  expect(statusText(ctx)).toBe("Thread created.");
});

step("no new worktree is created", (ctx: World) => {
  expect(callsTo(ctx, "createThread")[0]?.args[0]).toMatchObject({ createWorktree: false });
});

step("the project checkout switches to {string}", (ctx: World, branch: string) => {
  const root = projectNamed(ctx, "shop").workspaceRoot;
  expect(callsTo(ctx, "switchRef").map((call) => call.args)).toEqual([[root, branch]]);
  expect(callsTo(ctx, "createThread")[0]?.args[0]).toMatchObject({ branch, worktreePath: null });
});

step("the user chose a new worktree without a base branch", async (ctx: ThreadsWorld) => {
  threadNamed(ctx, ctx.subject!).branch = null;
  env(ctx).refs = [];
  await ui(ctx);
  await pressKey(ctx, "Ctrl+N");
  await flush(ctx);
  await click(ctx, await positionOf(ctx, "composerWorkspace"));
  await clickText(ctx, "New worktree");
  expect(draft(ctx)).toMatchObject({ workspaceMode: "new-worktree", branch: null });
});

step("the user tries to start the thread", async (ctx: World) => {
  await typeText(ctx, "Build the cart page");
  await pressKey(ctx, "Enter");
  await flush(ctx);
});

step("the user tries to start a thread with an empty first message", async (ctx: World) => {
  await ui(ctx);
  await pressKey(ctx, "Ctrl+N");
  await flush(ctx);
  await pressKey(ctx, "Enter");
  await flush(ctx);
});

step("the thread is not started", (ctx: World) => {
  expect(callsTo(ctx, "createThread")).toEqual([]);
  expect(draft(ctx)).not.toBeNull();
  expect(statusKind(ctx)).toBe("error");
});

step("the user is told to pick a base branch", async (ctx: World) => {
  expect(statusText(ctx)).toBe("Select a base branch before creating a new worktree.");
  expect(await snapshot(ctx)).toContain("Select a base branch");
});

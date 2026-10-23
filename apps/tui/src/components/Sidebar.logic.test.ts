import { describe, expect, it } from "bun:test";

import type { TuiThreadShell as OrchestrationThreadShell } from "../orchestrationV2Adapter.ts";
import type { OrchestrationShellSnapshot } from "../connection.ts";
import {
  buildRows,
  nextSidebarRefreshAt,
  type Row,
  rowHeight,
  SIDEBAR_SETTLED_INITIAL_COUNT,
  SIDEBAR_SETTLED_PAGE,
  SIDEBAR_SETTLED_SECTION_ID,
  SIDEBAR_SNOOZED_SECTION_ID,
  selectionEquals,
} from "./Sidebar.logic.ts";

const NOW = "2026-07-28T12:00:00.000Z";

function thread(
  id: string,
  projectId: string,
  input: Partial<OrchestrationThreadShell> = {},
): OrchestrationThreadShell {
  return {
    id,
    projectId,
    title: id,
    createdAt: "2026-07-28T10:00:00.000Z",
    updatedAt: "2026-07-28T10:00:00.000Z",
    archivedAt: null,
    settledOverride: null,
    settledAt: null,
    snoozedUntil: null,
    snoozedAt: null,
    latestUserMessageAt: null,
    latestTurn: null,
    session: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    ...input,
  } as OrchestrationThreadShell;
}

function shell(threads: readonly OrchestrationThreadShell[]): OrchestrationShellSnapshot {
  return {
    projects: [
      { id: "p1", title: "Alpha" },
      { id: "p2", title: "Beta" },
    ],
    threads,
  } as unknown as OrchestrationShellSnapshot;
}

const build = (
  snapshot: OrchestrationShellSnapshot,
  input: {
    expanded?: ReadonlySet<string>;
    shown?: number;
    selected?: string | null;
    filter?: string;
    project?: string | null;
    showPlugins?: boolean;
  } = {},
) =>
  buildRows(
    snapshot,
    input.expanded ?? new Set([SIDEBAR_SETTLED_SECTION_ID]),
    input.shown ?? SIDEBAR_SETTLED_INITIAL_COUNT,
    input.selected ?? null,
    input.filter ?? "",
    input.project ?? null,
    NOW,
    input.showPlugins ?? false,
  );

describe("Sidebar V2 row model", () => {
  it("schedules the next refresh at a snooze wake before the minute tick", () => {
    const nowMs = Date.parse(NOW);
    const wakeAt = nowMs + 5_000;
    expect(
      nextSidebarRefreshAt(
        shell([
          thread("snoozed", "p1", {
            snoozedAt: NOW,
            snoozedUntil: new Date(wakeAt).toISOString(),
          }),
        ]),
        nowMs,
      ),
    ).toBe(wakeAt);
  });

  it("schedules an idle refresh so relative-time labels stay current", () => {
    const nowMs = Date.parse(NOW) + 12_345;
    expect(nextSidebarRefreshAt(shell([thread("active", "p1")]), nowMs)).toBe(
      Math.floor(nowMs / 60_000) * 60_000 + 60_000,
    );
  });

  it("Given active threads, then it is flat and stable by creation time", () => {
    const rows = build(
      shell([
        thread("older-but-updated", "p1", {
          createdAt: "2026-07-28T09:00:00.000Z",
          updatedAt: "2026-07-28T11:59:00.000Z",
        }),
        thread("newer", "p2", {
          createdAt: "2026-07-28T11:00:00.000Z",
          updatedAt: "2026-07-28T11:00:00.000Z",
        }),
      ]),
    );

    expect(rows.map((row) => row.id)).toEqual(["newer", "older-but-updated"]);
    expect(rows.every((row) => row.kind === "thread")).toBe(true);
    expect(rows[0]).toMatchObject({
      kind: "thread",
      section: "active",
      projectTitle: "Beta",
    });
  });

  it("Given a project scope and search, then both filter the same flat list", () => {
    const snapshot = shell([
      thread("alpha-login", "p1", { title: "Fix login" }),
      thread("alpha-theme", "p1", { title: "Dark theme" }),
      thread("beta-login", "p2", { title: "Login throttle" }),
    ]);

    expect(build(snapshot, { project: "p1" }).map((row) => row.id)).toEqual([
      "alpha-login",
      "alpha-theme",
    ]);
    expect(build(snapshot, { filter: "beta" }).map((row) => row.id)).toEqual(["beta-login"]);
  });

  it("Given active, snoozed, and settled threads, then it builds the web shelf order", () => {
    const rows = build(
      shell([
        thread("active", "p1"),
        thread("snoozed", "p1", {
          snoozedAt: "2026-07-28T11:00:00.000Z",
          snoozedUntil: "2026-07-29T12:00:00.000Z",
        }),
        thread("settled", "p2", {
          settledOverride: "settled",
          settledAt: "2026-07-28T11:30:00.000Z",
        }),
      ]),
    );

    expect(rows.map((row) => row.id)).toEqual([
      "active",
      SIDEBAR_SNOOZED_SECTION_ID,
      SIDEBAR_SETTLED_SECTION_ID,
      "settled",
    ]);
    expect(rows[1]).toMatchObject({ kind: "section", expanded: false, count: 1 });
    expect(rows[2]).toMatchObject({ kind: "section", expanded: true, count: 1 });
  });

  it("Given a selected snoozed thread, then a collapsed shelf keeps it visible", () => {
    const rows = build(
      shell([
        thread("snoozed", "p1", {
          snoozedAt: "2026-07-28T11:00:00.000Z",
          snoozedUntil: "2026-07-29T12:00:00.000Z",
        }),
      ]),
      { selected: "snoozed" },
    );

    expect(rows.map((row) => row.id)).toEqual([SIDEBAR_SNOOZED_SECTION_ID, "snoozed"]);
  });

  it("Given more settled threads than the initial tail, then it pages and keeps a deep selection", () => {
    const settled = Array.from({ length: SIDEBAR_SETTLED_INITIAL_COUNT + 3 }, (_, index) =>
      thread(`settled-${index}`, "p1", {
        settledOverride: "settled",
        settledAt: new Date(Date.parse(NOW) - index * 1_000).toISOString(),
      }),
    );
    const rows = build(shell(settled), { selected: "settled-12" });
    const threadRows = rows.filter((row) => row.kind === "thread");

    expect(threadRows).toHaveLength(SIDEBAR_SETTLED_INITIAL_COUNT + 1);
    expect(threadRows.some((row) => row.id === "settled-12")).toBe(true);
    expect(rows.at(-1)).toMatchObject({ kind: "more", hiddenCount: 2 });
  });

  it("Given a long settled shelf, then each show more lists one more page", () => {
    const total = SIDEBAR_SETTLED_INITIAL_COUNT + SIDEBAR_SETTLED_PAGE + 5;
    const settled = Array.from({ length: total }, (_, index) =>
      thread(`settled-${index}`, "p1", {
        settledOverride: "settled",
        settledAt: new Date(Date.parse(NOW) - index * 1_000).toISOString(),
      }),
    );
    const listed = (shown: number) =>
      build(shell(settled), { shown }).filter((row) => row.kind === "thread").length;
    const more = (shown: number) => build(shell(settled), { shown }).at(-1);

    expect(listed(SIDEBAR_SETTLED_INITIAL_COUNT)).toBe(SIDEBAR_SETTLED_INITIAL_COUNT);
    expect(more(SIDEBAR_SETTLED_INITIAL_COUNT)).toMatchObject({
      kind: "more",
      hiddenCount: SIDEBAR_SETTLED_PAGE + 5,
    });
    const second = SIDEBAR_SETTLED_INITIAL_COUNT + SIDEBAR_SETTLED_PAGE;
    expect(listed(second)).toBe(second);
    expect(more(second)).toMatchObject({ kind: "more", hiddenCount: 5 });
    expect(listed(second + SIDEBAR_SETTLED_PAGE)).toBe(total);
    expect(more(second + SIDEBAR_SETTLED_PAGE)?.kind).toBe("thread");
  });

  it("Given settled plugin threads, then the shelf leaves them out unless asked, but search and the selection reach them", () => {
    const settled = (id: string, plugin = false) =>
      thread(id, "p1", {
        settledOverride: "settled",
        settledAt: "2026-07-28T11:00:00.000Z",
        ...(plugin ? { plugin: { id: "code-review", kind: "review", listed: true } } : {}),
      });
    const snapshot = shell([
      settled("mine"),
      settled("review", true),
      thread("open-review", "p1", { plugin: { id: "code-review", kind: "review", listed: true } }),
    ]);
    const shelf = (input: Parameters<typeof build>[1]) => {
      const rows = build(snapshot, input);
      const header = rows.find((row) => row.kind === "section" && row.section === "settled");
      const ids = rows.flatMap((row) =>
        row.kind === "thread" && row.section === "settled" ? [row.id] : [],
      );
      return { count: header?.kind === "section" ? header.count : 0, ids };
    };

    expect(shelf({})).toEqual({ count: 1, ids: ["mine"] });
    expect(shelf({ showPlugins: true })).toEqual({ count: 2, ids: ["mine", "review"] });
    expect(shelf({ filter: "review" })).toEqual({ count: 1, ids: ["review"] });
    expect(shelf({ selected: "review" }).ids).toContain("review");
    // Only settled ones: an active plugin thread stays where it is.
    expect(build(snapshot, {}).some((row) => row.id === "open-review")).toBe(true);
  });
});

describe("selection and row heights", () => {
  const activeRow = (id: string): Row => ({
    kind: "thread",
    id,
    thread: thread(id, "p1"),
    section: "active",
    projectTitle: "Alpha",
    timestamp: NOW,
  });

  it("Given matching selection identity, then selectionEquals is true", () => {
    expect(selectionEquals({ kind: "thread", id: "t1" }, activeRow("t1"))).toBe(true);
  });

  it("Given an active card, then it has room for metadata while shelf rows stay compact", () => {
    expect(rowHeight(activeRow("t1"))).toBe(4);
    expect(rowHeight({ ...activeRow("t2"), section: "settled" })).toBe(1);
    expect(
      rowHeight({
        kind: "section",
        id: SIDEBAR_SETTLED_SECTION_ID,
        section: "settled",
        title: "Settled",
        count: 1,
        expanded: true,
      }),
    ).toBe(1);
  });
});

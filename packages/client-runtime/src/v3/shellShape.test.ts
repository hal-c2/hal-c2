import { OrchestrationProjectShell, OrchestrationV2ThreadShell } from "@hal-c2/contracts";
import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

import { v2Project, v2ThreadShell } from "../state/orchestrationV2TestFixtures.ts";
import { ShellRows, ShellShapeFold, type ShellRow } from "./shellShape.ts";

const encodeProject = Schema.encodeSync(Schema.toCodecJson(OrchestrationProjectShell));
const encodeThread = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2ThreadShell));

const MC = "hal_c2@a";
const project = encodeProject(v2Project) as Record<string, unknown>;
const thread = (id: string, extra: Record<string, unknown> = {}) => ({
  ...(encodeThread(v2ThreadShell) as Record<string, unknown>),
  id,
  ...extra,
});

const projectRow = (): readonly [string, string, Record<string, unknown>] => [
  v2Project.id,
  "project",
  project,
];
const threadRow = (id: string, extra: Record<string, unknown> = {}) =>
  [id, "thread", thread(id, extra)] as const;
const snapshotRow = (row: readonly [string, string, Record<string, unknown>]): ShellRow => [
  MC,
  ...row,
];

const kinds = (items: ReturnType<ShellShapeFold["rows"]>) =>
  items.map((item) =>
    "threadId" in item
      ? `${item.kind}:${item.threadId}`
      : "projectId" in item
        ? `${item.kind}:${item.projectId}`
        : item.kind,
  );

describe("ShellShapeFold reset", () => {
  const seeded = () => {
    const fold = new ShellShapeFold(MC);
    fold.shell([
      snapshotRow(projectRow()),
      snapshotRow(threadRow("t-kept")),
      snapshotRow(threadRow("t-gone")),
      snapshotRow(threadRow("t-archived", { archivedAt: "2026-06-20T00:00:00.000Z" })),
    ]);
    return fold;
  };

  it("removes the rows a reset frame does not name, and updates the ones it does", () => {
    const fold = seeded();
    const items = fold.rows(MC, [projectRow(), threadRow("t-kept"), threadRow("t-new")], true);

    expect(kinds(items).toSorted()).toEqual([
      "project.updated",
      "thread.removed:t-archived",
      "thread.removed:t-gone",
      "thread.updated",
      "thread.updated",
    ]);
    // A removal says where the thread was, so the sidebar's archive loses it too.
    expect(
      items.find((item) => "threadId" in item && item.threadId === "t-archived"),
    ).toMatchObject({
      location: "archive",
    });
  });

  it("leaves the rows alone on a frame that is not a reset", () => {
    const fold = seeded();
    expect(kinds(fold.rows(MC, [threadRow("t-new")]))).toEqual(["thread.updated"]);
  });

  it("forgets a row a reset removed, and one a later row deleted", () => {
    const fold = seeded();
    fold.rows(MC, [threadRow("t-kept", { deletedAt: "2026-06-20T00:00:00.000Z" })]);
    fold.rows(MC, [projectRow()], true);
    // Nothing is left to remove the second time.
    expect(kinds(fold.rows(MC, [projectRow()], true))).toEqual(["project.updated"]);
  });

  it("ignores the rows of another MC", () => {
    const fold = seeded();
    expect(fold.rows("hal_c2@b", [], true)).toEqual([]);
    expect(kinds(fold.rows(MC, [projectRow()]))).toEqual(["project.updated"]);
  });
});

describe("ShellRows", () => {
  const OTHER = "hal_c2@b";
  const row = (mc: string, id: string): ShellRow => [mc, id, "thread", thread(id)];
  const ids = (rows: ReadonlyArray<ShellRow>) => rows.map(([mc, id]) => `${mc}/${id}`).sort();

  it("keeps an MC's rows across an answer that is not a reset, and adds what it carries", () => {
    const held = new ShellRows();
    held.answer(
      [
        { mc: MC, epoch: "e1", rev: 3 },
        { mc: OTHER, epoch: "f1", rev: 9 },
      ],
      [row(MC, "t1"), row(OTHER, "t2")],
    );
    expect(held.have()).toEqual({ [MC]: ["e1", 3], [OTHER]: ["f1", 9] });

    const all = held.answer(
      [
        { mc: MC, epoch: "e1", rev: 4, reset: false },
        { mc: OTHER, epoch: "f1", rev: 9, reset: false },
      ],
      [row(MC, "t3")],
    );
    expect(ids(all)).toEqual([`${MC}/t1`, `${MC}/t3`, `${OTHER}/t2`]);
    expect(held.have()).toEqual({ [MC]: ["e1", 4], [OTHER]: ["f1", 9] });
  });

  it("replaces an MC's rows on a reset, and drops an MC the answer no longer lists", () => {
    const held = new ShellRows();
    held.answer(
      [
        { mc: MC, epoch: "e1", rev: 3 },
        { mc: OTHER, epoch: "f1", rev: 9 },
      ],
      [row(MC, "t1"), row(OTHER, "t2")],
    );
    const all = held.answer([{ mc: MC, epoch: "e2", rev: 1, reset: true }], [row(MC, "t4")]);
    expect(ids(all)).toEqual([`${MC}/t4`]);
    expect(held.have()).toEqual({ [MC]: ["e2", 1] });
  });

  it("brings an MC to the [epoch, rev] of its changed rows", () => {
    const held = new ShellRows();
    held.answer([{ mc: MC, epoch: "e1", rev: 3 }], [row(MC, "t1")]);
    held.changed(MC, [["t5", "thread", thread("t5")]], false, "e1", 5);
    expect(held.have()).toEqual({ [MC]: ["e1", 5] });
    expect(ids(held.answer([{ mc: MC, epoch: "e1", rev: 5, reset: false }], []))).toEqual([
      `${MC}/t1`,
      `${MC}/t5`,
    ]);
  });
});

import { OrchestrationProjectShell, OrchestrationV2ThreadShell } from "@hal-c2/contracts";
import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

import { v2Project, v2ThreadShell } from "../state/orchestrationV2TestFixtures.ts";
import { ShellShapeFold, type ShellRow } from "./shellShape.ts";

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

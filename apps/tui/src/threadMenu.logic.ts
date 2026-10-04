import type { ContextMenuItem } from "@hal-c2/contracts";

import type { Row } from "./components/Sidebar.logic.ts";

// The thread row's context menu, shared by the React sidebar and the QML host.

export type ThreadContextMenuAction =
  | "settle"
  | "unsettle"
  | "rename"
  | "copy-path"
  | "copy-branch"
  | "copy-thread-id"
  | "move"
  | "archive"
  | "delete";

export const MOVE_THREAD_LABEL = "Move to another machine…";

export function buildThreadContextMenuItems(input: {
  readonly row: Pick<Extract<Row, { kind: "thread" }>, "section" | "thread">;
  readonly settlementSupported: boolean;
  readonly hasWorkspacePath: boolean;
  /** The cluster has another machine the thread could move to. */
  readonly canMove?: boolean;
}): ReadonlyArray<ContextMenuItem<ThreadContextMenuAction>> {
  const { row } = input;
  const settled = row.section === "settled";
  return [
    ...(input.settlementSupported
      ? [
          settled
            ? { id: "unsettle" as const, label: "Un-settle thread" }
            : // The server owns the settle rules; a rejection reaches the status line.
              { id: "settle" as const, label: "Settle thread" },
        ]
      : []),
    {
      id: "rename",
      label: "Rename thread",
      separatorBefore: input.settlementSupported,
    },
    {
      id: "copy-path",
      label: "Copy path",
      disabled: !input.hasWorkspacePath,
      separatorBefore: true,
    },
    ...(row.thread.branch ? [{ id: "copy-branch" as const, label: "Copy branch" }] : []),
    { id: "copy-thread-id", label: "Copy thread ID" },
    ...(input.canMove
      ? [{ id: "move" as const, label: MOVE_THREAD_LABEL, separatorBefore: true }]
      : []),
    {
      id: "archive",
      label: "Archive thread",
      disabled: row.thread.session?.status === "running",
      separatorBefore: !input.canMove,
    },
    { id: "delete", label: "Delete", destructive: true },
  ];
}

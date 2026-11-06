import type { ContextMenuItem } from "@hal-c2/contracts";

import type { Row } from "./sidebar.logic.ts";

// The thread row's context menu, used by the QML host.

export type ThreadContextMenuAction =
  | "settle"
  | "unsettle"
  | "auto-settle"
  | "snooze"
  | "unsnooze"
  | "rename"
  | "copy-path"
  | "copy-branch"
  | "copy-thread-id"
  | "move"
  | "archive"
  | "delete";

export const MOVE_THREAD_LABEL = "Move to another machine…";
export const AUTO_SETTLE_MENU_LABEL = "Auto-settle behavior…";

export function buildThreadContextMenuItems(input: {
  readonly row: Pick<Extract<Row, { kind: "thread" }>, "section" | "thread">;
  readonly settlementSupported: boolean;
  /** The server understands thread.auto-settle.set (`capabilities.threadAutoSettleOptOut`). */
  readonly autoSettleOptOutSupported?: boolean;
  readonly hasWorkspacePath: boolean;
  /** Whether the thread may be snoozed now; omitted by a host that cannot snooze. */
  readonly canSnooze?: boolean;
  /** The cluster has another machine the thread could move to. */
  readonly canMove?: boolean;
}): ReadonlyArray<ContextMenuItem<ThreadContextMenuAction>> {
  const { row } = input;
  const settled = row.section === "settled";
  const snooze =
    input.canSnooze === undefined
      ? []
      : [
          row.section === "snoozed"
            ? { id: "unsnooze" as const, label: "Wake thread" }
            : { id: "snooze" as const, label: "Snooze", disabled: !input.canSnooze },
        ];
  return [
    ...(input.settlementSupported
      ? [
          settled
            ? { id: "unsettle" as const, label: "Un-settle thread" }
            : // The server owns the settle rules; a rejection reaches the status line.
              { id: "settle" as const, label: "Settle thread" },
        ]
      : []),
    // A setting, not a lifecycle verb: it opens the Enabled / Disabled choice.
    ...(input.autoSettleOptOutSupported
      ? [{ id: "auto-settle" as const, label: AUTO_SETTLE_MENU_LABEL }]
      : []),
    {
      id: "rename",
      label: "Rename thread",
      separatorBefore: input.settlementSupported || input.autoSettleOptOutSupported === true,
    },
    ...snooze,
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

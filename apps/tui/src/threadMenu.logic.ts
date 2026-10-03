import type { ContextMenuItem } from "@hal-c2/contracts";

import type { Row } from "./components/Sidebar.logic.ts";

// The thread row's context menu, shared by the React sidebar and the QML host.

export type ThreadContextMenuAction =
  | "settle"
  | "unsettle"
  | "snooze"
  | "unsnooze"
  | "rename"
  | "copy-path"
  | "copy-branch"
  | "copy-thread-id"
  | "archive"
  | "delete";

export function buildThreadContextMenuItems(input: {
  readonly row: Pick<Extract<Row, { kind: "thread" }>, "section" | "thread">;
  readonly settlementSupported: boolean;
  readonly hasWorkspacePath: boolean;
  /** Whether the thread may be snoozed now; omitted by a host that cannot snooze. */
  readonly canSnooze?: boolean;
  /** Entries a host adds after the copy group (moving the thread). */
  readonly extra?: ReadonlyArray<ContextMenuItem>;
}): ReadonlyArray<ContextMenuItem<ThreadContextMenuAction | string>> {
  const { row } = input;
  const settled = row.section === "settled";
  const extra = input.extra ?? [];
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
    {
      id: "rename",
      label: "Rename thread",
      separatorBefore: input.settlementSupported,
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
    ...extra.map((item, index) => (index === 0 ? { ...item, separatorBefore: true } : item)),
    {
      id: "archive",
      label: "Archive thread",
      disabled: row.thread.session?.status === "running",
      separatorBefore: true,
    },
    { id: "delete", label: "Delete", destructive: true },
  ];
}

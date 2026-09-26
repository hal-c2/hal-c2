import type { ShellDesktopNotification, ShellNotification } from "@t3tools/contracts/shell";

import type { OrchestrationShellSnapshot } from "../connection.ts";

// In-app alerts for threads the user is not looking at, published under
// `notifications` (the desktop toast contract). Mirrors the web's
// createDesktopNotificationTracker: only transitions raise an alert, never the
// state a thread was already in when the client connected.

type ShellThread = OrchestrationShellSnapshot["threads"][number];
type AlertKind = ShellDesktopNotification["kind"];

const ALERTS: Partial<Record<AlertKind, Pick<ShellNotification, "type" | "title">>> = {
  completed: { type: "success", title: "Thread completed" },
  approval: { type: "warning", title: "Approval needed" },
  input: { type: "warning", title: "Input needed" },
  error: { type: "error", title: "Thread failed" },
};

/** Alerts kept on screen; older ones drop off. */
const MAX_ALERTS = 3;

export interface ThreadAlert extends ShellNotification {
  readonly threadId: string;
}

export const OPEN_THREAD_ACTION = "open";

/** The transitions between two shell snapshots worth an alert, oldest first. */
export function threadTransitions(
  before: ReadonlyArray<ShellThread> | null,
  after: ReadonlyArray<ShellThread>,
): Array<{ readonly thread: ShellThread; readonly kind: AlertKind }> {
  if (!before) return [];
  const previous = new Map(before.map((thread) => [thread.id, thread]));
  const events: Array<{ thread: ShellThread; kind: AlertKind }> = [];
  for (const thread of after) {
    const was = previous.get(thread.id);
    if (!was || thread.archivedAt) continue;
    const turn = thread.latestTurn;
    const turnChanged =
      turn !== null && (was.latestTurn?.turnId !== turn.turnId || was.latestTurn?.state !== turn.state);
    if (turnChanged && turn.state === "completed") events.push({ thread, kind: "completed" });
    if (thread.hasPendingApprovals && !was.hasPendingApprovals) events.push({ thread, kind: "approval" });
    if (thread.hasPendingUserInput && !was.hasPendingUserInput) events.push({ thread, kind: "input" });
    if (turnChanged && turn.state === "error") events.push({ thread, kind: "error" });
  }
  return events;
}

/**
 * Fold new transitions into the alert list: a newer alert for a thread
 * replaces its older one, the viewed thread never alerts, newest first.
 */
export function nextThreadAlerts(
  alerts: ReadonlyArray<ThreadAlert>,
  transitions: ReturnType<typeof threadTransitions>,
  viewedThreadId: string | null,
  nextId: () => string,
): ReadonlyArray<ThreadAlert> {
  let next = [...alerts];
  for (const { thread, kind } of transitions) {
    const alert = ALERTS[kind];
    if (!alert || thread.id === viewedThreadId) continue;
    next = [
      {
        id: nextId(),
        threadId: thread.id,
        ...alert,
        description: thread.title,
        updateKey: 0,
        actions: [{ id: OPEN_THREAD_ACTION, label: "Open", primary: true }],
      },
      ...next.filter((existing) => existing.threadId !== thread.id),
    ];
  }
  return next.slice(0, MAX_ALERTS);
}

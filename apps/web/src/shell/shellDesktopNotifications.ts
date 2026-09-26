import type { EnvironmentThreadShell } from "@hal-c2/client-runtime/state/models";
import { scopeThreadRef, scopedThreadKey } from "@hal-c2/client-runtime/environment";
import type { ShellDesktopNotification } from "@hal-c2/contracts/shell";

import { randomUUID } from "../lib/utils";

type NotificationThread = Pick<
  EnvironmentThreadShell,
  | "id"
  | "environmentId"
  | "title"
  | "archivedAt"
  | "latestRun"
  | "hasPendingApprovals"
  | "hasPendingUserInput"
  | "runtimeMode"
>;

/** Observes transitions, not historical completions on initial load or new environments. */
export function createDesktopNotificationTracker() {
  const instanceId = randomUUID();
  let previous = new Map<string, NotificationThread>();
  let sequence = 0;
  return (threads: ReadonlyArray<NotificationThread>): ShellDesktopNotification[] => {
    const next = new Map<string, NotificationThread>();
    const events: ShellDesktopNotification[] = [];
    for (const thread of threads) {
      const key = scopedThreadKey(scopeThreadRef(thread.environmentId, thread.id));
      next.set(key, thread);
      const before = previous.get(key);
      if (!before || thread.archivedAt !== null) continue;
      const emit = (kind: ShellDesktopNotification["kind"]) => {
        events.push({
          id: `${instanceId}:${key}:${++sequence}`,
          threadKey: key,
          kind,
          threadTitle: thread.title,
          runtimeMode: thread.runtimeMode,
        });
      };
      const run = thread.latestRun;
      if (
        run?.status === "completed" &&
        run.completedAt !== null &&
        (before.latestRun?.runId !== run.runId || before.latestRun?.status !== "completed")
      ) {
        emit("completed");
      }
      if (thread.hasPendingApprovals && !before.hasPendingApprovals) {
        emit("approval");
      }
      if (thread.hasPendingUserInput && !before.hasPendingUserInput) emit("input");
      if (
        run &&
        (before.latestRun?.runId !== run.runId || before.latestRun?.status !== run.status)
      ) {
        if (run.status === "running") emit("started");
        if (run.status === "failed") emit("error");
      }
    }
    previous = next;
    return events;
  };
}

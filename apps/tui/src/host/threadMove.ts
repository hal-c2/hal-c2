import type { ContextMenuItem } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";
import { clip } from "../format.ts";
import type { TuiThreadShell } from "../orchestrationV2Adapter.ts";
import type { Store } from "../store.ts";
import type { PaletteCommand } from "./paletteState.ts";
import { threadKey } from "./sidebarState.ts";
import type { ThreadSubmenu } from "./threadActions.ts";

// Moving a thread to another machine of the cluster. The MC does the move
// (`hal-c2.moveThread`); this asks where to, offers to stop a running turn
// first, and puts the MC's questions (what stays behind, which project) to
// the user before sending the move again.

/** The thread menu's entry (`MOVE_THREAD_ITEM`) and the action behind it and the palette's. */
export const MOVE_THREAD_ITEM = "move";

interface Destination {
  readonly machine: string;
  readonly environmentId?: string;
  readonly online: boolean;
}

interface MoveAnswer {
  readonly status?: string;
  readonly message?: string;
  readonly notes?: ReadonlyArray<string | { readonly message?: string }>;
  readonly projects?: ReadonlyArray<{ readonly id: string; readonly title: string }>;
}

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

export function createThreadMove(ctx: {
  readonly client: Pick<TuiClient, "mcCall" | "interrupt">;
  readonly store: Store;
  /** True while this machine has other machines in its cluster. */
  readonly clustered: () => boolean;
  /** Show a menu of choices for the thread, in the thread menu's place. */
  readonly openSubmenu: (thread: TuiThreadShell, submenu: ThreadSubmenu) => void;
}) {
  const { client, store } = ctx;
  const pending = new Set<Promise<unknown>>();
  const track = <T>(promise: Promise<T>): Promise<T> => {
    pending.add(promise);
    const done = () => pending.delete(promise);
    promise.then(done, done);
    return promise;
  };
  const failed = (error: unknown) =>
    store.setStatus(`Failed to move thread: ${errorText(error)}`, "error");
  const shellThread = (id: string) =>
    store.getState().shell?.threads.find((thread) => thread.id === id) ?? null;
  const running = (thread: TuiThreadShell | null) => thread?.session?.status === "running";

  const header = (label: string): ContextMenuItem => ({ id: "header", label, header: true });

  const move = (
    thread: TuiThreadShell,
    machine: string,
    extra: { readonly projectId?: string; readonly confirmed?: boolean } = {},
  ) => {
    store.setStatus(`Moving ${thread.title} to ${machine}…`, "busy");
    void track(
      client
        .mcCall<MoveAnswer>("hal-c2.moveThread", { threadId: thread.id, machine, ...extra })
        .then((answer) => {
          if (answer?.status === "confirm") {
            const notes = (answer.notes ?? [])
              .map((note) => (typeof note === "string" ? note : (note.message ?? "")))
              .filter((note) => note !== "");
            store.setStatus(`Move ${thread.title} to ${machine}?`, "info");
            ctx.openSubmenu(thread, {
              items: [
                header(`Move ${clip(thread.title, 24)} to ${machine}?`),
                ...(notes.length > 0 ? notes : [answer.message ?? ""])
                  .filter((note) => note !== "")
                  .map((note, index) => ({ id: `note-${index}`, label: note, header: true })),
                { id: "confirm", label: "Move", separatorBefore: true },
                { id: "cancel", label: "Cancel" },
              ],
              choose: (id) => {
                if (id === "confirm") move(thread, machine, { ...extra, confirmed: true });
                else store.setStatus(`${thread.title} was not moved.`, "info");
              },
            });
          } else if (answer?.status === "choose_project") {
            store.setStatus(`Which project on ${machine}?`, "info");
            ctx.openSubmenu(thread, {
              items: [
                header(`Move into which project on ${machine}?`),
                ...(answer.projects ?? []).map((project) => ({
                  id: project.id,
                  label: project.title,
                })),
              ],
              choose: (projectId) => move(thread, machine, { ...extra, projectId }),
            });
          } else {
            store.setStatus(answer?.message || `${thread.title} moved to ${machine}.`, "success");
          }
        }, failed),
    );
  };

  /** Interrupt the running turn, and move once the thread's row says it has stopped. */
  const stopAndMove = (thread: TuiThreadShell, machine: string) => {
    store.setStatus(`Stopping ${thread.title}…`, "busy");
    void track(
      new Promise<void>((resolve) => {
        let unsubscribe: (() => void) | null = null;
        let finished = false;
        const finish = () => {
          finished = true;
          unsubscribe?.();
          unsubscribe = null;
          resolve();
        };
        const check = () => {
          const now = shellThread(thread.id);
          if (finished || running(now)) return;
          finish();
          if (now) move(now, machine);
        };
        unsubscribe = store.subscribe(check);
        client.interrupt(thread.id as never).then(check, (error: unknown) => {
          finish();
          store.setStatus(`Failed to stop the turn: ${errorText(error)}`, "error");
        });
      }),
    );
  };

  /** Ask which machine the thread goes to. */
  const choose = (thread: TuiThreadShell) => {
    void track(
      client
        .mcCall<ReadonlyArray<Destination>>("hal-c2.moveDestinations", { threadId: thread.id })
        .then((destinations) => {
          const list = Array.isArray(destinations) ? destinations : [];
          if (list.length === 0) {
            store.setStatus("No other machine can take this thread.", "info");
            return;
          }
          store.setStatus(`Which machine should ${thread.title} move to?`, "info");
          ctx.openSubmenu(thread, {
            items: [
              header(`Move ${clip(thread.title, 24)} to`),
              ...list.map((destination) => ({
                id: destination.machine,
                label: destination.online
                  ? destination.machine
                  : `${destination.machine} (offline)`,
                disabled: !destination.online,
              })),
            ],
            choose: (machine) => {
              const now = shellThread(thread.id) ?? thread;
              if (!running(now)) return move(now, machine);
              // The MC does not move a thread whose turn is running: stopping it first is offered.
              ctx.openSubmenu(now, {
                items: [
                  header(`${clip(now.title, 24)} is running`),
                  { id: "stop", label: `Stop it and move to ${machine}` },
                  { id: "cancel", label: "Cancel" },
                ],
                choose: (id) => {
                  if (id === "stop") stopAndMove(now, machine);
                },
              });
            },
          });
        }, failed),
    );
  };

  return {
    /** The thread menu's entry: only on a machine with others to move to. */
    menuItems: (): ReadonlyArray<ContextMenuItem> =>
      ctx.clustered() ? [{ id: MOVE_THREAD_ITEM, label: "Move to another machine…" }] : [],
    runMenuItem: (thread: TuiThreadShell, id: string): boolean => {
      if (id !== MOVE_THREAD_ITEM) return false;
      choose(thread);
      return true;
    },
    paletteCommands: (thread: TuiThreadShell | null): PaletteCommand[] =>
      thread && ctx.clustered()
        ? [
            {
              id: "thread.move",
              title: "Move thread to another machine…",
              keywords: "cluster machine transfer migrate",
              action: "thread.move",
              payload: { key: threadKey(thread.id) },
            },
          ]
        : [],
    choose,
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
  };
}

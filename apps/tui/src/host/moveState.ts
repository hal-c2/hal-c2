import type { ThreadMoveInput } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";
import type { TuiThreadShell } from "../orchestrationV2Adapter.ts";
import { shellSummary, type Store } from "../store.ts";
import type { Composer, PickRequest } from "./composerState.ts";

type MoveThread = Pick<TuiThreadShell, "id" | "title">;
/** Where a thread moves to: labels are the user's own and may repeat, so the id is what is sent. */
interface MoveMachine {
  readonly id: string;
  readonly label: string;
}
type MoveOption = PickRequest["options"][number];

const CANCEL = "cancel";

const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

/** A sentence over as many picker rows as it needs, none of which can be chosen. */
const noteRows = (note: string, width: number): MoveOption[] => {
  const lines: string[] = [];
  let line = "";
  for (const word of note.split(/\s+/).filter((part) => part !== "")) {
    if (line !== "" && line.length + 1 + word.length > width) {
      lines.push(line);
      line = word;
    } else {
      line = line === "" ? word : `${line} ${word}`;
    }
  }
  if (line !== "") lines.push(line);
  return lines.map((label) => ({ label, description: "", value: "", disabled: true }));
};

/**
 * Moving a thread to another machine of the cluster. The MC that holds the
 * thread does the move; this asks where to, relays what the MC asks back
 * (leave things behind? which project?), and says how the agent continues.
 */
export function createMoveController(ctx: {
  readonly client: TuiClient;
  readonly store: Store;
  readonly pick: Composer["pick"];
  /** The picker's inner width, for wrapping what a move leaves behind. */
  readonly width: () => number;
}) {
  const { client, store } = ctx;
  const pending = new Set<Promise<unknown>>();
  const track = (promise: Promise<unknown>) => {
    pending.add(promise);
    const done = () => pending.delete(promise);
    promise.then(done, done);
  };
  /** Threads whose turn is being stopped so they can move, by where they go. */
  const stopping = new Map<
    string,
    { readonly thread: MoveThread; readonly machine: MoveMachine }
  >();
  /** How the last move ended, kept on the status row over the snapshots the move itself causes. */
  let told: string | null = null;

  const shellThread = (id: string) =>
    store.getState().shell?.threads.find((thread) => thread.id === id);
  const running = (id: string) => shellThread(id)?.session?.status === "running";

  const move = (
    thread: MoveThread,
    machine: MoveMachine,
    extra: Pick<ThreadMoveInput, "projectId" | "confirmed"> = {},
  ) => {
    told = null;
    store.setStatus(`Moving "${thread.title}" to ${machine.label}…`, "busy");
    track(
      client.moveThread({ threadId: thread.id, machine: machine.id, ...extra }).then(
        (result) => {
          switch (result.status) {
            case "moved":
              told = result.message || `${thread.title} moved to ${machine.label}.`;
              // The user follows the thread: a list scoped to the project it left would hide it.
              if (store.getState().projectScopeId !== null) store.setProjectScope(result.projectId);
              store.select({ kind: "thread", id: thread.id });
              store.setStatus(told, "success");
              return;
            case "confirm":
              store.setStatus(result.message);
              ctx.pick({
                title: `Move "${thread.title}" to ${machine.label}?`,
                status: "ready",
                options: [
                  ...result.notes.flatMap((note) => noteRows(note, Math.max(16, ctx.width() - 6))),
                  { label: "Move", description: "", value: "move" },
                  { label: "Cancel", description: "", value: CANCEL },
                ],
                onChoose: (value) => {
                  if (value === CANCEL) store.setStatus(`${thread.title} was not moved.`);
                  else move(thread, machine, { ...extra, confirmed: true });
                },
              });
              return;
            case "choose_project":
              store.setStatus(result.message);
              ctx.pick({
                title: `Move "${thread.title}" into which project on ${machine.label}?`,
                status: "ready",
                options: result.projects.map((project) => ({
                  label: project.title,
                  description: project.workspaceRoot,
                  value: project.id,
                })),
                onChoose: (projectId) => move(thread, machine, { ...extra, projectId }),
              });
              return;
          }
        },
        (error: unknown) => store.setStatus(errorText(error), "error"),
      ),
    );
  };

  /** The MC refuses to move a running thread: offer to stop its turn first. */
  const stopAndMove = (thread: MoveThread, machine: MoveMachine) => {
    ctx.pick({
      title: `Stop "${thread.title}" and move it to ${machine.label}?`,
      status: "ready",
      options: [
        { label: "Stop and move", description: "Interrupts the running turn.", value: "stop" },
        { label: "Cancel", description: "", value: CANCEL },
      ],
      onChoose: (value) => {
        if (value === CANCEL) return;
        stopping.set(thread.id, { thread, machine });
        store.setStatus(`Stopping "${thread.title}"…`, "busy");
        track(
          client.interrupt(thread.id).then(
            () => sync(),
            (error: unknown) => {
              stopping.delete(thread.id);
              store.setStatus(`Stop failed: ${errorText(error)}`, "error");
            },
          ),
        );
      },
    });
  };

  /** Follow the shell: move what has stopped, and keep the move's outcome on the status row. */
  const sync = () => {
    for (const [id, { thread, machine }] of stopping) {
      if (running(id)) continue;
      stopping.delete(id);
      if (shellThread(id)) move(thread, machine);
    }
    if (told === null) return;
    const { shell, status } = store.getState();
    if (status === told) return;
    // A snapshot's summary replaced it: say it again. Anything else was said after it.
    if (shell && status === shellSummary(shell)) store.setStatus(told, "success");
    else told = null;
  };

  return {
    /** Whether there is another machine to move to at all. */
    available: () => (store.getState().shell?.machines?.length ?? 0) > 1,
    /** Ask which machine `thread` moves to, then move it. */
    start: (thread: MoveThread) => {
      let labels = new Map<string, string>();
      const update = ctx.pick({
        title: `Move "${thread.title}" to`,
        status: "loading",
        options: [],
        onChoose: (id) => {
          const machine = { id, label: labels.get(id) ?? id };
          if (running(thread.id)) stopAndMove(thread, machine);
          else move(thread, machine);
        },
      });
      track(
        client.moveDestinations(thread.id).then(
          (destinations) => {
            labels = new Map(
              destinations.map(({ environmentId, machine }) => [environmentId, machine]),
            );
            update({
              status: "ready",
              options: destinations
                .toSorted((a, b) => a.machine.localeCompare(b.machine))
                .map((destination) => ({
                  label: destination.online
                    ? destination.machine
                    : `${destination.machine} (offline)`,
                  description:
                    destination.projects.find((project) => project.sameRepository)?.workspaceRoot ??
                    "",
                  value: destination.environmentId,
                  ...(destination.online ? {} : { disabled: true }),
                })),
            });
            if (destinations.length === 0) {
              store.setStatus("No other machine can take this thread.", "error");
            }
          },
          (error: unknown) => {
            update({ status: "error", options: [] });
            store.setStatus(errorText(error), "error");
          },
        ),
      );
    },
    sync,
    /** Resolves once every move call in flight has landed (tests wait on it). */
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
  };
}

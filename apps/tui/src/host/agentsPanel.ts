import type { PropertyMap } from "opentui-qml";

import type { OrchestrationThread } from "../connection.ts";
import type { TuiThreadExtras } from "../orchestrationV2Adapter.ts";
import type { Store, StoreState } from "../store.ts";
import {
  agentTitle,
  buildTuiAgentsState,
  type AgentBlock,
  type TuiAgentsState,
} from "./agentsState.ts";
import type { PickRequest } from "./composerState.ts";

/** The `layout.rightPanel.kind` of the agents panel. */
export const AGENTS_PANEL = "agents";

const payloadIndex = (payload: unknown): number | undefined => {
  const index =
    typeof payload === "object" && payload !== null
      ? (payload as Record<string, unknown>).index
      : undefined;
  return typeof index === "number" && Number.isInteger(index) ? index : undefined;
};

/**
 * The agents panel (`Shell.state.agents`, `agents.*`): the open thread's
 * workers, what each is doing and for how long. Enter follows a worker's own
 * thread; `c` stops it after asking. The host owns the panel slot and
 * forwards store changes (`publish`), open/close (`panelChanged`) and actions.
 */
export function createAgentsPanel(deps: {
  readonly store: Store;
  readonly state: PropertyMap;
  /** Whether the agents panel is open and has the keys. */
  readonly panel: () => { readonly open: boolean; readonly focused: boolean };
  /** The panel's size in cells, border included. */
  readonly size: () => { readonly width: number; readonly height: number };
  readonly nowMs: () => number;
  /** Ask the user to choose (the picker). */
  readonly menu: (spec: PickRequest) => void;
  /**
   * Open a thread in the conversation pane: the keys go to it (a worker's
   * timeline to follow) unless `keepFocus` leaves them on the panel.
   */
  readonly openThread: (threadId: string, options?: { readonly keepFocus?: boolean }) => void;
  /** Stop a thread's run and what it delegated (`run.interrupt`, `stopDelegated`). */
  readonly interrupt: (threadId: string) => Promise<void>;
}) {
  const { store, state } = deps;
  let selectedId: string | null = null;

  const blocks = (shell: StoreState["shell"]): ReadonlyMap<string, AgentBlock> =>
    new Map(
      (shell?.threads ?? []).flatMap((thread) =>
        thread.hasPendingApprovals || thread.hasPendingUserInput
          ? [
              [
                thread.id as string,
                { approval: thread.hasPendingApprovals, question: thread.hasPendingUserInput },
              ] as const,
            ]
          : [],
      ),
    );

  /** On a worker's own thread: the thread that started it, the way back. */
  const parentId = (): string | null => {
    const { detail, shell } = store.getState();
    const lineage = detail
      ? shell?.threads.find((thread) => thread.id === detail.id)?.lineage
      : undefined;
    return lineage?.relationshipToParent === "subagent" ? (lineage.parentThreadId ?? null) : null;
  };

  const agentsState = (): TuiAgentsState & { readonly parent: string | null } => {
    const { detail, shell } = store.getState();
    const agents = (detail as (OrchestrationThread & TuiThreadExtras) | null)?.subagents ?? [];
    const parent = parentId();
    const size = deps.size();
    return {
      ...buildTuiAgentsState({
        agents,
        blocks: blocks(shell),
        selectedId,
        nowMs: deps.nowMs(),
        width: size.width,
        // The "↳ parent" line takes a row from the workers.
        height: size.height - (parent ? 1 : 0),
      }),
      parent: parent
        ? (shell?.threads.find((thread) => thread.id === parent)?.title ?? "its parent thread")
        : null,
    };
  };

  let shown = agentsState();
  const publishAgents = () => {
    shown = agentsState();
    selectedId = shown.ids[shown.selectedIndex] ?? null;
    state.set("agents", shown);
  };

  /** The worker a key or a click acts on: the one at `index`, else the selected one. */
  const target = (payload: unknown) => {
    const index = payloadIndex(payload);
    if (index !== undefined && shown.ids[index]) {
      selectedId = shown.ids[index]!;
      publishAgents();
    }
    const id = shown.ids[shown.selectedIndex];
    const detail = store.getState().detail as (OrchestrationThread & TuiThreadExtras) | null;
    const agent = detail?.subagents?.find((entry) => entry.id === id) ?? null;
    const row = shown.rows.find((entry) => entry.id === id) ?? null;
    return agent && row ? { agent, row } : null;
  };

  const open = (payload: unknown) => {
    const found = target(payload);
    if (!found) return;
    if (!found.agent.childThreadId) {
      store.setStatus("This subagent runs inside its provider's turn; it has no thread to open.");
      return;
    }
    deps.openThread(found.agent.childThreadId);
  };

  const stop = (payload: unknown) => {
    const found = target(payload);
    if (!found) return;
    const { agent, row } = found;
    const title = agentTitle(agent);
    if (row.state !== "working" && row.state !== "blocked") {
      store.setStatus(`${title} already ended.`);
      return;
    }
    if (!agent.childThreadId) {
      store.setStatus("This subagent runs inside its provider's turn; stop the turn instead.");
      return;
    }
    const childThreadId = agent.childThreadId;
    deps.menu({
      title: `Stop ${title}?`,
      returnMode: deps.panel().focused ? AGENTS_PANEL : "compose",
      options: [
        {
          label: "Stop the worker",
          description: "Its run ends, with what it delegated; the thread that started it is told.",
          value: "stop",
        },
        { label: "Keep it running", description: "Nothing is stopped.", value: "keep" },
      ],
      index: 1,
      onChoose: (choice) => {
        if (choice !== "stop") return;
        deps.interrupt(childThreadId).then(
          () => store.setStatus(`Stopping ${title}…`, "success"),
          () => store.setStatus(`Could not stop ${title}.`, "error"),
        );
      },
    });
  };

  const dispatch = (action: string, payload?: unknown): boolean => {
    switch (action) {
      case "agents.next":
      case "agents.previous": {
        const count = shown.ids.length;
        if (count === 0) return true;
        const step = action === "agents.next" ? 1 : count - 1;
        selectedId = shown.ids[(shown.selectedIndex + step) % count]!;
        publishAgents();
        return true;
      }
      case "agents.select":
        target(payload);
        return true;
      case "agents.open":
        open(payload);
        return true;
      case "agents.stop":
        stop(payload);
        return true;
      case "agents.parent": {
        const parent = parentId();
        if (parent) deps.openThread(parent, { keepFocus: true });
        return true;
      }
      // The panel's clock (AgentsPanel's Timer): elapsed times move while something works.
      case "agents.tick":
        if (deps.panel().open) publishAgents();
        return true;
      default:
        return false;
    }
  };

  const publish = (prev: StoreState | null, next: StoreState) => {
    if (!prev || prev.detail !== next.detail || prev.shell !== next.shell) {
      // Another thread's workers: start at the top.
      if (prev?.detail?.id !== next.detail?.id) selectedId = null;
      publishAgents();
    }
  };

  let publishedSize = "";
  return {
    dispatch,
    publish,
    /** The panel was resized: its rows clip and window to the new size. */
    resize: () => {
      const size = JSON.stringify(deps.size());
      if (size === publishedSize) return;
      publishedSize = size;
      publishAgents();
    },
    /** The panel opened (highlight the first worker that needs the user) or closed. */
    panelChanged: (open: boolean) => {
      if (open) selectedId = null;
      publishAgents();
    },
  };
}

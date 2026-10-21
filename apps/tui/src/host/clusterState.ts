import type { ClusterInvite, ClusterStatus, ClusterUpdateResult } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";
import type { Store } from "../store.ts";
import type { TuiMode } from "./layoutState.ts";
import type { PaletteCommand } from "./paletteState.ts";

/**
 * Published under `cluster`: this machine's cluster as the MC reports it
 * (null until first read), the last invite, and whether the one-line join
 * prompt is open (mode "join").
 */
export interface TuiClusterState {
  readonly status: ClusterStatus | null;
  /** Why the status could not be read (an older server, no access). */
  readonly error: string | null;
  readonly invite: ClusterInvite | null;
  readonly joining: boolean;
}

export const NO_CLUSTER_STATE: TuiClusterState = {
  status: null,
  error: null,
  invite: null,
  joining: false,
};

/** What the loopback hint tells the user to do instead. */
export const LOCAL_ONLY_HINT =
  "Only this machine can open it: the MC listens on loopback. Invite over Tailscale instead.";

const errorText = (error: unknown): string =>
  error instanceof Error ? error.message : String(error);

/** What `cluster.update` did, one sentence per member, and whether any could not update. */
export function updateSummary(result: ClusterUpdateResult): { text: string; failed: boolean } {
  let failed = false;
  const lines = result.members.map(({ label, outcome }) => {
    if (outcome === "updated") return `${label} updated to ${result.version}.`;
    if (outcome === "restarting on it") return `${label} is restarting on ${result.version}.`;
    if (outcome === "has not finished") return `${label} is still updating.`;
    failed = true;
    return `${label} could not update: ${outcome}`;
  });
  if (lines.length === 0) lines.push(`Every machine already runs ${result.version}.`);
  return { text: lines.join(" "), failed };
}

/**
 * The cluster from the terminal: status in settings, and invite, join,
 * remove and sending this machine's version to the others from the
 * palette. The MC does the work (`cluster.*`); this reads the status again when the MC says a machine came or went, when settings
 * or the palette open, and after each change.
 */
export function createClusterController(ctx: {
  readonly client: TuiClient;
  readonly store: Store;
  readonly setMode: (mode: TuiMode) => void;
  readonly restingMode: () => TuiMode;
  readonly copyToClipboard: ((text: string) => boolean) | undefined;
  readonly publish: (state: TuiClusterState) => void;
}) {
  const { client, store } = ctx;
  let current = NO_CLUSTER_STATE;
  const pending = new Set<Promise<unknown>>();
  const set = (next: Partial<TuiClusterState>) => {
    current = { ...current, ...next };
    ctx.publish(current);
  };
  const track = <T>(promise: Promise<T>): Promise<T> => {
    pending.add(promise);
    const done = () => pending.delete(promise);
    promise.then(done, done);
    return promise;
  };

  // Bumped by every read and change: RPCs answer concurrently, so a read sent
  // before a join or remove may land after it, and only the latest request counts.
  let generation = 0;
  const refresh = () => {
    const asked = ++generation;
    return track(
      client.clusterStatus().then(
        (status) => {
          if (asked === generation) set({ status, error: null });
        },
        (error: unknown) => {
          if (asked === generation) set({ error: errorText(error) });
        },
      ),
    );
  };

  const invite = (tailscale: boolean) => {
    store.setStatus("Making a cluster invite…");
    void track(
      client.clusterInvite(tailscale ? { tailscale } : {}).then(
        (next) => {
          set({ invite: next });
          const copied = ctx.copyToClipboard?.(next.link) === true;
          const hint = next.localOnly ? ` ${LOCAL_ONLY_HINT}` : "";
          store.setStatus(
            `${copied ? "Invite link copied" : "Invite link in settings"}; join with it on the other machine.${hint}`,
            next.localOnly ? "error" : "success",
          );
        },
        (error: unknown) => store.setStatus(`Invite failed: ${errorText(error)}`, "error"),
      ),
    );
  };

  const change = (promise: Promise<ClusterStatus>, success: string, failure: string) => {
    generation += 1;
    void track(
      promise.then(
        (status) => {
          set({ status, error: null });
          store.setStatus(success, "success");
        },
        (error: unknown) => {
          store.setStatus(`${failure}: ${errorText(error)}`, "error");
          // In place of any read this change overtook.
          void refresh();
        },
      ),
    );
  };

  const closeJoin = () => {
    set({ joining: false });
    ctx.setMode(ctx.restingMode());
  };

  const members = () => (current.status?.clustered ? current.status.members : []);
  // Connected members that run another version than this machine.
  const behind = () => {
    const status = current.status;
    if (!status?.clustered) return [];
    return status.members.filter(
      (member) => member.connected && member.version && member.version !== status.version,
    );
  };

  // Members restart or load the version in place, so the cluster is read again after.
  const update = () => {
    store.setStatus("Sending this version to the other machines…");
    void track(
      client.clusterUpdate().then(
        (result) => {
          const { text, failed } = updateSummary(result);
          store.setStatus(text, failed ? "error" : "success");
          void refresh();
        },
        (error: unknown) => {
          store.setStatus(`Update failed: ${errorText(error)}`, "error");
          void refresh();
        },
      ),
    );
  };

  return {
    state: () => current,
    refresh,
    /** Resolves once every cluster call in flight has landed (tests wait on it). */
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
    commands: (): PaletteCommand[] => [
      {
        id: "cluster.invite",
        title: "Invite a machine to this cluster",
        keywords: "cluster join link pair",
        action: "cluster.invite",
      },
      {
        id: "cluster.invite.tailscale",
        title: "Invite a machine over Tailscale",
        keywords: "cluster join link pair tailnet",
        action: "cluster.invite",
        payload: { tailscale: true },
      },
      {
        id: "cluster.join",
        title: "Join another machine's cluster…",
        keywords: "cluster invite link",
        action: "cluster.join.open",
      },
      ...(behind().length > 0
        ? [
            {
              id: "cluster.update",
              title: "Send this version to the other machines",
              keywords: "cluster update upgrade release members",
              action: "cluster.update",
            },
          ]
        : []),
      ...members().map((member) => ({
        id: `cluster.remove.${member.id}`,
        title: `Remove ${member.label} from the cluster`,
        keywords: "cluster member",
        action: "cluster.remove",
        payload: { id: member.id },
      })),
    ],
    dispatch: (action: string, payload: unknown): boolean => {
      const field = (name: string) =>
        typeof payload === "object" && payload !== null
          ? (payload as Record<string, unknown>)[name]
          : undefined;
      switch (action) {
        case "cluster.refresh":
          void refresh();
          return true;
        case "cluster.invite":
          invite(field("tailscale") === true);
          return true;
        case "cluster.join.open":
          set({ joining: true });
          ctx.setMode("join");
          return true;
        case "cluster.join.cancel":
          closeJoin();
          return true;
        case "cluster.join": {
          const link = String(field("link") ?? "").trim();
          if (link === "") {
            store.setStatus("Paste the invite link from the other machine.", "error");
            return true;
          }
          closeJoin();
          store.setStatus("Joining the cluster…");
          change(client.clusterJoin(link), "Joined the cluster.", "Join failed");
          return true;
        }
        case "cluster.update":
          update();
          return true;
        case "cluster.remove": {
          const id = field("id");
          if (typeof id !== "string") return true;
          const label = members().find((member) => member.id === id)?.label ?? id;
          change(client.clusterRemove(id), `Removed ${label} from the cluster.`, "Remove failed");
          return true;
        }
        default:
          return false;
      }
    },
  };
}

import * as Schema from "effect/Schema";

/**
 * One person's machines as one cluster (apps/server-ex `HalC2.Cluster`). A machine
 * joins with an invite, a one-time pairing link from any member; members then
 * reach each other over pinned mutual TLS with nothing else to set up.
 */

export const ClusterMember = Schema.Struct({
  /** The member's environment id. */
  id: Schema.String,
  label: Schema.String,
  /** Where it was last reported listening for members, `host:port`. */
  addresses: Schema.Array(Schema.String),
  /** The HAL-C2 version it last reported. A member on another version does not connect. */
  version: Schema.optional(Schema.NullOr(Schema.String)),
  connected: Schema.Boolean,
});
export type ClusterMember = typeof ClusterMember.Type;

export const ClusterStatus = Schema.Union([
  Schema.Struct({
    clustered: Schema.Literal(true),
    /** This machine's environment id, label and member addresses. */
    id: Schema.String,
    label: Schema.String,
    mc: Schema.String,
    addresses: Schema.Array(Schema.String),
    /** The HAL-C2 version this machine runs. */
    version: Schema.optional(Schema.String),
    /** The other members. */
    members: Schema.Array(ClusterMember),
  }),
  /** The MC was started without cluster support; `reason` says why. */
  Schema.Struct({ clustered: Schema.Literal(false), reason: Schema.String }),
]);
export type ClusterStatus = typeof ClusterStatus.Type;

export const ClusterInviteInput = Schema.Struct({
  /** Where the other machine reaches this MC; by default where it listens. */
  baseUrl: Schema.optional(Schema.String),
  /** Reach this MC through its Tailscale Serve name, publishing it if need be. */
  tailscale: Schema.optional(Schema.Boolean),
});
export type ClusterInviteInput = typeof ClusterInviteInput.Type;

export const ClusterInvite = Schema.Struct({
  /** A pairing link granting `access:write`, good once. */
  link: Schema.String,
  expiresAt: Schema.String,
  /** Only this machine can reach the link: the node listens on loopback. */
  localOnly: Schema.Boolean,
});
export type ClusterInvite = typeof ClusterInvite.Type;

export const ClusterJoinInput = Schema.Struct({ link: Schema.String });
export type ClusterJoinInput = typeof ClusterJoinInput.Type;

export const ClusterRemoveInput = Schema.Struct({ id: Schema.String });
export type ClusterRemoveInput = typeof ClusterRemoveInput.Type;

/**
 * Moving a thread to another machine of the cluster (apps/server-ex
 * `HalC2.ThreadMove`). The MC that holds the thread does the move, so these are
 * asked of that machine.
 */
export const ThreadMoveProject = Schema.Struct({
  id: Schema.String,
  title: Schema.String,
  workspaceRoot: Schema.String,
  /** A checkout of the repository the thread's project is. */
  sameRepository: Schema.optional(Schema.Boolean),
});
export type ThreadMoveProject = typeof ThreadMoveProject.Type;

/** Another member the thread could move to; one that is offline lists no projects. */
export const ThreadMoveDestination = Schema.Struct({
  machine: Schema.String,
  environmentId: Schema.String,
  online: Schema.Boolean,
  projects: Schema.Array(ThreadMoveProject),
});
export type ThreadMoveDestination = typeof ThreadMoveDestination.Type;

export const ThreadMoveInput = Schema.Struct({
  threadId: Schema.String,
  /**
   * The destination's environment id. A label is taken too when only one machine has
   * it (labels are the user's own, and may repeat), for a destination named by hand.
   */
  machine: Schema.String,
  /** The project to land in, when the destination has several that fit. */
  projectId: Schema.optional(Schema.String),
  /** The user accepted what the move leaves behind (a `confirm` answer's notes). */
  confirmed: Schema.optional(Schema.Boolean),
});
export type ThreadMoveInput = typeof ThreadMoveInput.Type;

export const ThreadMoveResult = Schema.Union([
  Schema.Struct({
    status: Schema.Literal("moved"),
    threadId: Schema.String,
    machine: Schema.String,
    environmentId: Schema.String,
    projectId: Schema.String,
    /** The agent continues its own session there; otherwise it gets a summary. */
    sessionCarried: Schema.Boolean,
    /** What to tell the user: where the thread went and how the agent continues. */
    message: Schema.String,
    notes: Schema.Array(Schema.String),
  }),
  /** Nothing moved: ask again with `confirmed` once the user accepts the notes. */
  Schema.Struct({
    status: Schema.Literal("confirm"),
    message: Schema.String,
    notes: Schema.Array(Schema.String),
  }),
  /** Nothing moved: ask again with one of these as `projectId`. */
  Schema.Struct({
    status: Schema.Literal("choose_project"),
    message: Schema.String,
    projects: Schema.Array(ThreadMoveProject),
  }),
]);
export type ThreadMoveResult = typeof ThreadMoveResult.Type;

/**
 * Where a new thread starts (`hal-c2.placeThread`, apps/server-ex
 * `HalC2.LoadBalancing`). A client asks the MC it is connected to, naming the
 * machine and project the user picked, and starts the thread where the answer
 * says. The MC reads `loadBalancingEnabled` and `loadBalancingWeights` from its
 * settings document, and answers with the user's pick when balancing is off.
 */
export const ThreadPlacementInput = Schema.Struct({
  environmentId: Schema.String,
  projectId: Schema.String,
  /** The agent the thread will run on; machines that cannot run it are passed over. */
  instanceId: Schema.optional(Schema.String),
});
export type ThreadPlacementInput = typeof ThreadPlacementInput.Type;

/** The machine chosen and its own checkout of the project's repository. */
export const ThreadPlacement = Schema.Struct({
  environmentId: Schema.String,
  projectId: Schema.String,
});
export type ThreadPlacement = typeof ThreadPlacement.Type;

export class ClusterError extends Schema.TaggedError<ClusterError>()("ClusterError", {
  /** `link_lacks_access`, `link_invalid`, `unreachable`, `not_booted_for_clustering`, ... */
  reason: Schema.String,
  message: Schema.String,
}) {}

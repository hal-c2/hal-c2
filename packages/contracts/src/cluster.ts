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

export class ClusterError extends Schema.TaggedError<ClusterError>()("ClusterError", {
  /** `link_lacks_access`, `link_invalid`, `unreachable`, `not_booted_for_clustering`, ... */
  reason: Schema.String,
  message: Schema.String,
}) {}

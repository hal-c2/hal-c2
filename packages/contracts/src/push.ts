import * as Schema from "effect/Schema";

/**
 * Agent push (apps/server-ex `HalC2.Push`): a phone registers a UnifiedPush endpoint with the
 * MC it is paired with, and the MC POSTs WebPush-encrypted (RFC 8291, `aes128gcm`)
 * `PushMessage`s to it when agents finish, fail or need the user. No HAL-C2-hosted service
 * carries them. The MC decides content and recipients (mutes, quiet hours, live activity);
 * the phone decides presentation.
 */

export const PushQuietHours = Schema.Struct({
  /** Minutes after local midnight; `start > end` wraps past midnight. */
  start: Schema.Int,
  end: Schema.Int,
  /** Approval and input alerts go through inside the window. */
  allowApprovals: Schema.Boolean,
  /** The phone's offset from UTC; it registers again when the offset changes. */
  utcOffsetMinutes: Schema.Int,
});
export type PushQuietHours = typeof PushQuietHours.Type;

export const PushRegistrationInput = Schema.Struct({
  /** The UnifiedPush endpoint the distributor gave the phone. */
  endpoint: Schema.String,
  keys: Schema.Struct({
    /** base64url, a 65-byte uncompressed P-256 point. */
    p256dh: Schema.String,
    /** base64url, 16 bytes. */
    auth: Schema.String,
  }),
  /** The distributor's package, such as `io.heckel.ntfy`. */
  distributor: Schema.String,
  /** Send activity card updates as well as alerts. */
  liveActivity: Schema.Boolean,
  /** `<environmentId>:<threadId>` keys that get no alerts. */
  mutedThreads: Schema.Array(Schema.String),
  quietHours: Schema.NullOr(PushQuietHours),
});
export type PushRegistrationInput = typeof PushRegistrationInput.Type;

export class InvalidPushRegistration extends Schema.TaggedError<InvalidPushRegistration>()(
  "InvalidPushRegistration",
  { message: Schema.String },
) {}

export const PushAlertKind = Schema.Literals(["completed", "failed", "approval", "input", "grouped"]);
export type PushAlertKind = typeof PushAlertKind.Type;

export const PushAlert = Schema.Struct({
  /** The same alert has the same id on every retry and redelivery. */
  id: Schema.String,
  kind: PushAlertKind,
  title: Schema.String,
  body: Schema.String,
  /** `hal-c2://threads/<environmentId>/<threadId>`; a grouped alert's is its first thread's. */
  link: Schema.String,
  environmentId: Schema.String,
  threadId: Schema.String,
});
export type PushAlert = typeof PushAlert.Type;

export const PushActivityPhase = Schema.Literals([
  "starting",
  "running",
  "waiting_for_approval",
  "waiting_for_input",
  "stale",
  "completed",
  "failed",
]);
export type PushActivityPhase = typeof PushActivityPhase.Type;

export const PushActivityRow = Schema.Struct({
  /** Connecting, Working, Approval, Input, Waiting, Done or Failed. */
  status: Schema.String,
  title: Schema.String,
  project: Schema.String,
  environmentId: Schema.String,
  threadId: Schema.String,
});
export type PushActivityRow = typeof PushActivityRow.Type;

export const PushActivity = Schema.Struct({
  /** Any row not finished. */
  active: Schema.Boolean,
  /** The first row's; absent when there are no rows. */
  phase: Schema.optional(PushActivityPhase),
  expiresAt: Schema.Number,
  activeCount: Schema.Number,
  attentionCount: Schema.Number,
  link: Schema.optional(Schema.String),
  environmentId: Schema.optional(Schema.String),
  threadId: Schema.optional(Schema.String),
  /** At most 5, most urgent first. */
  rows: Schema.Array(PushActivityRow),
});
export type PushActivity = typeof PushActivity.Type;

/** The plaintext JSON of one push, before encryption. */
export const PushMessage = Schema.Struct({
  v: Schema.Literal(1),
  /** The MC's wall clock, ms since the epoch, when it sent the message. */
  sentAt: Schema.Number,
  /** Absent when the message only updates the activity card. */
  alert: Schema.optional(PushAlert),
  /** Absent when the registration has `liveActivity: false`. */
  activity: Schema.optional(PushActivity),
});
export type PushMessage = typeof PushMessage.Type;

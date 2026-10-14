import * as Schema from "effect/Schema";

import { TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * An MC's Slack connection (`HalC2.Slack`), the one workspace its plugins reach Slack
 * through. The tokens stay in the MC's secret store: no payload carries them, and
 * `tokensSet` is all a client learns.
 */
export const SlackConnectionState = Schema.Literals([
  "off",
  "connecting",
  "connected",
  "reconnecting",
  "failed",
]);
export type SlackConnectionState = typeof SlackConnectionState.Type;

export const SlackStatus = Schema.Struct({
  state: SlackConnectionState,
  /** The workspace and the bot, once connected. */
  team: Schema.NullOr(Schema.String),
  teamId: Schema.NullOr(Schema.String),
  bot: Schema.NullOr(Schema.String),
  botUserId: Schema.NullOr(Schema.String),
  /** Why it failed, with Slack's reason when Slack gave one. */
  error: Schema.NullOr(Schema.String),
  tokensSet: Schema.Boolean,
});
export type SlackStatus = typeof SlackStatus.Type;

/**
 * The MC's Slack methods, over the protocol 3 `rpc` frame. Like the plugin methods
 * they are the MC's own, so they sit outside `WS_METHODS`. `connect` checks both
 * tokens with Slack before keeping them; `disconnect` forgets them.
 */
export const SLACK_METHODS = {
  status: "slack.status",
  connect: "slack.connect",
  disconnect: "slack.disconnect",
  manifest: "slack.manifest",
} as const;

export const SlackConnectInput = Schema.Struct({
  /** `xoxb-…`, the bot's token. */
  botToken: TrimmedNonEmptyString,
  /** `xapp-…` with `connections:write`, for Socket Mode. */
  appToken: TrimmedNonEmptyString,
});

/** The Slack app manifest (YAML) a user pastes into api.slack.com to make the app. */
export const SlackManifestResult = Schema.Struct({ manifest: Schema.String });

/**
 * `{type: "slack", mc}` pushes `{t: "slack", status}` at once and on every change.
 * It is about one MC's host, so it is named by MC.
 */
export const SlackShape = Schema.Struct({
  type: Schema.Literal("slack"),
  mc: TrimmedNonEmptyString,
});

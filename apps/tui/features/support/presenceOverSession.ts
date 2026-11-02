// Presence the way the app has it: the real settings client over an environment
// session, the fake MC behind the session. The usual fake settings client stands in
// for that client, so it cannot show what the client does when the MC cannot say.
import { EnvironmentSupervisor } from "@hal-c2/client-runtime/connection";
import type { RpcSession } from "@hal-c2/client-runtime/rpc";
import {
  type SpaceId,
  type SpacePageId,
  type SpacePresenceViewer,
  WS_METHODS,
} from "@hal-c2/contracts";
import * as Cause from "effect/Cause";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as ManagedRuntime from "effect/ManagedRuntime";
import * as Option from "effect/Option";
import * as Queue from "effect/Queue";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

import { ClusterRpcError } from "../../../../packages/client-runtime/src/v3/clusterSocket.ts";
import { makeTuiSettingsClient } from "../../src/settingsClient.ts";
import type { FakeSettingsMc } from "./fakeSettingsMc.ts";

export interface PresenceOverSession {
  /** The MC can no longer say: whoever it was telling hears so, as do those who ask. */
  readonly refuse: () => void;
  readonly answer: () => void;
  /** Resolves once `check` passes, checked again each time the client is told something. */
  readonly until: (check: () => boolean) => Promise<void>;
}

/** Routes `settings.presence` through the real settings client. Attach the fake MC first. */
export function presenceOverSession(settings: FakeSettingsMc): PresenceOverSession {
  const served = settings.presence!;
  const refused = () => new ClusterRpcError("MC unavailable: noconnection", undefined);
  let refusing = false;
  const listening = new Set<() => void>();
  const waiting = new Set<() => void>();

  const presence = ({ pageId }: { readonly pageId: string }) =>
    refusing
      ? Stream.fail(refused())
      : Stream.callback<{ viewers: ReadonlyArray<SpacePresenceViewer> }, ClusterRpcError>((queue) =>
          Effect.acquireRelease(
            Effect.sync(() => {
              const refuse = () => Queue.failCauseUnsafe(queue, Cause.fail(refused()));
              const stop = served(pageId, (viewers) => Queue.offerUnsafe(queue, { viewers }));
              listening.add(refuse);
              return () => {
                listening.delete(refuse);
                stop();
              };
            }),
            (stop) => Effect.sync(stop),
          ),
        );

  const session = {
    client: { [WS_METHODS.subscribeSpacePresence]: presence },
  } as unknown as RpcSession;
  const supervisor = {
    target: { environmentId: "presence-test" },
    session: Effect.runSync(SubscriptionRef.make(Option.some(session))),
  } as unknown as EnvironmentSupervisor["Service"];
  const client = makeTuiSettingsClient(
    ManagedRuntime.make(Layer.succeed(EnvironmentSupervisor, supervisor)),
  );

  settings.presence = (pageId, onViewers) =>
    client.subscribeSpacePresence("space" as SpaceId, pageId as SpacePageId, (viewers) => {
      onViewers(viewers);
      for (const wake of waiting) wake();
    });

  return {
    refuse: () => {
      refusing = true;
      for (const refuse of listening) refuse();
    },
    answer: () => {
      refusing = false;
    },
    until: (check) =>
      new Promise((resolve) => {
        const run = () => {
          if (!check()) return;
          waiting.delete(run);
          resolve();
        };
        waiting.add(run);
        run();
      }),
  };
}

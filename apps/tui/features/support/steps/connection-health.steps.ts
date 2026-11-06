// Connection health from the terminal (features/connections/connection-health.feature):
// a protocol mismatch blocks the launch with advice.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { runClient, runningMc, type LaunchWorld } from "../launchWorld.ts";

interface HealthWorld extends LaunchWorld {
  connectBy?: () => Promise<void>;
}

// --- A protocol mismatch --------------------------------------------------------

/** The client speaks protocols 2 and 3; these are one past either end. */
const PROTOCOLS = {
  "a newer protocol than the client": 4,
  "an older protocol than the client": 1,
} as const;

step(
  /^an environment whose MC speaks (a newer protocol than the client|an older protocol than the client)$/,
  (ctx: HealthWorld, protocol: string) => {
    runningMc(ctx, { protocol: PROTOCOLS[protocol as keyof typeof PROTOCOLS] });
    // The real client, launched against that MC; it exits instead of drawing when blocked.
    ctx.connectBy = async () => {
      await runClient(ctx, {});
    };
  },
);

step("the connection is blocked", (ctx: HealthWorld) => {
  const run = ctx.client!;
  expect(run.drew).toBe(false);
  expect(run.code).not.toBe(0);
  // Blocked on the descriptor: no socket ticket, no socket.
  expect(ctx.mc!.ticketRequests).toHaveLength(0);
  expect(ctx.mc!.sockets).toHaveLength(0);
});

step(
  /^the client says (update HAL-C2 on (?:this device|that environment))$/,
  (ctx: HealthWorld, advice: string) => {
    expect(ctx.client!.stderr.toLowerCase()).toContain(advice.toLowerCase());
  },
);

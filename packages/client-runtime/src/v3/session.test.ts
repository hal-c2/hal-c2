import { WS_METHODS } from "@hal-c2/contracts";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";

import { ClusterRpcError, type ClusterSocket, type ShapeFrame } from "./clusterSocket.ts";
import { makeV3Session } from "./session.ts";

const ENVIRONMENT = "environment-here";

/** The smallest config a protocol-3 client decodes (as the TUI's fake MC sends it). */
const CONFIG = {
  auth: {
    policy: "loopback-browser",
    bootstrapMethods: ["one-time-token"],
    sessionMethods: ["bearer-access-token"],
    sessionCookieName: "hal_c2_session",
  },
  availableEditors: [],
  cwd: "/srv/mc",
  environment: {
    environmentId: ENVIRONMENT,
    label: "Here",
    platform: { os: "linux", arch: "x64" },
    serverVersion: "0.0.0",
    orchestrationProtocolVersion: 3,
    capabilities: {},
  },
  issues: [],
  keybindingRules: [],
  keybindings: [],
  keybindingsConfigPath: "/srv/mc/keybindings.json",
  observability: {
    localTracingEnabled: false,
    logsDirectoryPath: "/srv/mc/logs",
    otlpLogsEnabled: false,
    otlpMetricsEnabled: false,
    otlpTracesEnabled: false,
  },
  providers: [],
  settings: {},
};

/** A socket whose MC answers the config shape and each RPC with `answer`. */
function socketAnswering(answer: (method: string, payload: unknown) => Promise<unknown>) {
  const calls: Array<{ environment: string; method: string; payload: unknown }> = [];
  const socket = {
    subscribe: (_shape: unknown, listener: (frame: ShapeFrame) => void) => {
      queueMicrotask(() => listener({ t: "config", mc: "hal_c2@here", config: CONFIG }));
      return () => {};
    },
    call: (environment: string, method: string, payload: unknown) => {
      calls.push({ environment, method, payload });
      return answer(method, payload);
    },
  } as unknown as ClusterSocket;
  return { socket, calls };
}

describe("makeV3Session", () => {
  it.effect("asks its own MC where another machine's file is here", () =>
    Effect.gen(function* () {
      const { socket, calls } = socketAnswering(async () => ({
        path: "/home/user/.local/state/hal-c2/elixir/machines/laptop/src/app.ts",
      }));
      const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT });
      const payload = { environmentId: "environment-laptop", path: "/home/me/src/app.ts" };

      const answer = yield* session.client[WS_METHODS.filesLocalPath](payload as never);

      expect(answer).toEqual({
        path: "/home/user/.local/state/hal-c2/elixir/machines/laptop/src/app.ts",
      });
      expect(calls).toEqual([
        { environment: ENVIRONMENT, method: WS_METHODS.filesLocalPath, payload },
      ]);
    }),
  );

  it.effect("fails as the contract's error when the MC refuses", () =>
    Effect.gen(function* () {
      const { socket } = socketAnswering(() =>
        Promise.reject(new ClusterRpcError("path must be absolute", undefined)),
      );
      const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT });

      const error = yield* Effect.flip(
        session.client[WS_METHODS.filesLocalPath]({
          environmentId: "environment-laptop",
          path: "src/app.ts",
        } as never),
      );

      expect(error).toMatchObject({
        _tag: "FilesLocalPathError",
        path: "src/app.ts",
        message: "path must be absolute",
      });
    }),
  );
});

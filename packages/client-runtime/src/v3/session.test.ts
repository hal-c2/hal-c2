import {
  OrchestrationV2AppThread,
  ORCHESTRATION_V2_WS_METHODS,
  type OrchestrationV2ThreadStreamItem,
  WS_METHODS,
} from "@hal-c2/contracts";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";
import * as Stream from "effect/Stream";

import { v2Projection, v2ThreadId } from "../state/orchestrationV2TestFixtures.ts";
import {
  ClusterRpcError,
  type ClusterSocket,
  type ShapeFrame,
  type StreamResumePoint,
} from "./clusterSocket.ts";
import { makeV3Session, ThreadResumes } from "./session.ts";

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

  describe("a terminal attached with acks", () => {
    const attach = { threadId: "thread-1", terminalId: "term-1" };

    /** A socket whose MC answers an attach with one frame, recording what was asked. */
    function terminalSocket() {
      const { socket, calls: _calls } = socketAnswering(async () => null);
      const acks: number[] = [];
      const shapes: Array<{ readonly acknowledged: boolean; readonly shape: unknown }> = [];
      const answer = (shape: { readonly type: string }, listener: (frame: ShapeFrame) => void) =>
        queueMicrotask(() =>
          listener(
            shape.type === "terminal"
              ? { t: "terminal", event: { type: "output", data: "x", sequence: 1 } }
              : { t: "config", mc: "hal_c2@here", config: CONFIG },
          ),
        );
      socket.subscribe = ((shape: { readonly type: string }, listener: never) => {
        if (shape.type === "terminal") shapes.push({ acknowledged: false, shape });
        answer(shape, listener);
        return () => {};
      }) as never;
      socket.subscribeAcknowledged = ((shape: never, listener: never) => {
        shapes.push({ acknowledged: true, shape });
        answer(shape, listener);
        return { unsubscribe: () => {}, ack: (sequence: number) => acks.push(sequence) };
      }) as never;
      return { socket, acks, shapes };
    }

    const inputOf = (shape: unknown) => (shape as { readonly input: object }).input;

    it.effect("acknowledges on the attach while it lasts, and asks the MC for no acks field", () =>
      Effect.gen(function* () {
        const { socket, acks, shapes } = terminalSocket();
        const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT });
        const stream = session.client[WS_METHODS.terminalAttach]({
          ...attach,
          acks: true,
        } as never) as unknown as Stream.Stream<unknown>;

        yield* stream.pipe(
          Stream.take(1),
          Stream.runForEach(() =>
            Effect.sync(() => session.ackTerminal?.(attach.threadId, attach.terminalId, 1)),
          ),
        );
        expect(acks).toEqual([1]);
        expect(shapes).toHaveLength(1);
        expect(shapes[0]!.acknowledged).toBe(true);
        expect(inputOf(shapes[0]!.shape)).toEqual(attach);

        // The attach has ended, and an ack still on its way goes nowhere.
        session.ackTerminal?.(attach.threadId, attach.terminalId, 2);
        expect(acks).toEqual([1]);
      }),
    );

    it.effect("leaves an attach without acks to be sent everything", () =>
      Effect.gen(function* () {
        const { socket, acks, shapes } = terminalSocket();
        const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT });
        const stream = session.client[WS_METHODS.terminalAttach](
          attach as never,
        ) as unknown as Stream.Stream<unknown>;

        yield* stream.pipe(
          Stream.take(1),
          Stream.runForEach(() =>
            Effect.sync(() => session.ackTerminal?.(attach.threadId, attach.terminalId, 1)),
          ),
        );
        expect(shapes.map((shape) => shape.acknowledged)).toEqual([false]);
        expect(acks).toEqual([]);
      }),
    );
  });

  it.effect("follows who else is on a page, by the page's own shape", () =>
    Effect.gen(function* () {
      const shapes: Array<{ readonly type: string }> = [];
      const socket = {
        subscribe: (shape: { readonly type: string }, listener: (frame: ShapeFrame) => void) => {
          shapes.push(shape);
          queueMicrotask(() =>
            listener(
              shape.type === "spacePresence"
                ? {
                    t: "spacePresence",
                    viewers: [{ type: "agent", threadId: "t1", title: "Plans" }],
                  }
                : { t: "config", mc: "hal_c2@here", config: CONFIG },
            ),
          );
          return () => {};
        },
      } as unknown as ClusterSocket;
      const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT });

      const first = yield* session.client[WS_METHODS.subscribeSpacePresence]({
        spaceId: "s1",
        pageId: "p1",
      } as never).pipe(Stream.runHead);

      expect(Option.getOrThrow(first)).toEqual({
        viewers: [{ type: "agent", threadId: "t1", title: "Plans" }],
      });
      expect(shapes.at(-1)).toEqual({
        type: "spacePresence",
        mc: "hal_c2@here",
        spaceId: "s1",
        pageId: "p1",
      });
    }),
  );

  it.effect("fails who else is on a page when the MC cannot say", () =>
    Effect.gen(function* () {
      const socket = {
        subscribe: (shape: { readonly type: string }, listener: (frame: ShapeFrame) => void) => {
          queueMicrotask(() =>
            listener(
              shape.type === "spacePresence"
                ? { t: "error", reason: "MC unavailable: noconnection" }
                : { t: "config", mc: "hal_c2@here", config: CONFIG },
            ),
          );
          return () => {};
        },
      } as unknown as ClusterSocket;
      const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT });

      const error = yield* Effect.flip(
        session.client[WS_METHODS.subscribeSpacePresence]({
          spaceId: "s1",
          pageId: "p1",
        } as never).pipe(Stream.runDrain),
      );

      expect(error).toBeInstanceOf(ClusterRpcError);
      expect((error as unknown as ClusterRpcError).message).toBe("MC unavailable: noconnection");
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

  it.effect("tells why the MC refused a terminal", () =>
    Effect.gen(function* () {
      const { socket } = socketAnswering(() =>
        Promise.reject(
          new ClusterRpcError("refused", {
            _tag: "TerminalProviderEnvironmentError",
            providerInstanceId: "codex",
            cause: "settings.json cannot be read",
            reason: "settings.json cannot be read",
          }),
        ),
      );
      const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT });

      const error = yield* Effect.flip(
        session.client[WS_METHODS.terminalOpen]({
          threadId: "thread-1",
          terminalId: "term-1",
          cwd: "/work/app",
          providerInstanceId: "codex",
        } as never),
      );

      expect(error.message).toContain("settings.json cannot be read");
    }),
  );
});

describe("makeV3Session thread resumes", () => {
  const thread = Schema.encodeSync(Schema.toCodecJson(OrchestrationV2AppThread))(
    v2Projection.thread,
  ) as Record<string, unknown>;

  /** A socket whose thread stream sends a snapshot at offset 9 and an event at 12. */
  function socketStreaming() {
    const resumes: Array<StreamResumePoint | undefined> = [];
    const socket = {
      subscribe: (_shape: unknown, listener: (frame: ShapeFrame) => void) => {
        queueMicrotask(() => listener({ t: "config", mc: "hal_c2@here", config: CONFIG }));
        return () => {};
      },
      subscribeWindow: (
        _shape: unknown,
        _items: number,
        listener: (frame: ShapeFrame) => void,
        _floor: unknown,
        resume?: StreamResumePoint,
      ) => {
        resumes.push(resume);
        queueMicrotask(() => {
          listener({
            t: "snapshot",
            rows: [["thread", v2ThreadId, thread]],
            part: 0,
            done: true,
            offset: 9,
            floor: null,
          });
          listener({ t: "events", offset: 12, events: [[12, "thread", v2ThreadId, {}, 12]] });
        });
        return {
          unsubscribe: () => {},
          more: () => true,
          resumePoint: () => ({ offset: 12, floor: null, handle: "log-1" }),
        };
      },
    } as unknown as ClusterSocket;
    return { socket, resumes };
  }

  const subscribe = (
    socket: ClusterSocket,
    store: ThreadResumes,
    request: Record<string, unknown>,
  ) =>
    Effect.gen(function* () {
      const session = yield* makeV3Session({ socket, environmentId: ENVIRONMENT, resumes: store });
      const thread = session.client[ORCHESTRATION_V2_WS_METHODS.subscribeThread] as unknown as (
        request: unknown,
      ) => Stream.Stream<OrchestrationV2ThreadStreamItem>;
      return yield* Stream.runCollect(
        thread({ threadId: v2ThreadId, ...request }).pipe(Stream.take(2)),
      );
    });

  it.effect("carries a replaced session's stream on when the thread state holds all of it", () =>
    Effect.gen(function* () {
      const { socket, resumes } = socketStreaming();
      const store = new ThreadResumes();
      yield* subscribe(socket, store, {});
      yield* subscribe(socket, store, { afterSequence: 12 });
      expect(resumes).toEqual([undefined, { offset: 12, floor: null, handle: "log-1" }]);
    }),
  );

  it.effect("loads the thread again when the thread state is behind the stream", () =>
    Effect.gen(function* () {
      const { socket, resumes } = socketStreaming();
      const store = new ThreadResumes();
      yield* subscribe(socket, store, {});
      yield* subscribe(socket, store, { afterSequence: 9 });
      expect(resumes).toEqual([undefined, undefined]);
    }),
  );
});

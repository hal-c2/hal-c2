// @effect-diagnostics anyUnknownInErrorContext:off
// @effect-diagnostics unknownInEffectCatch:off
// @effect-diagnostics globalErrorInEffectFailure:off
// @effect-diagnostics globalFetch:off
import * as NodeFS from "node:fs";

import {
  type ClusterInvite,
  type ClusterInviteInput,
  type ClusterStatus,
  EnvironmentId,
  type MessageId,
  MessageId as MessageIdSchema,
  type ModelSelection,
  NonNegativeInt,
  ORCHESTRATION_V2_WS_METHODS,
  type OrchestrationThread,
  type OrchestrationV2ShellSnapshot,
  type OrchestrationV2ThreadDetailSnapshot,
  PlanId,
  type ProjectId,
  ProjectId as ProjectIdSchema,
  type ProjectEntry,
  type ProjectReadFileResult,
  type ProviderApprovalDecision,
  PositiveInt,
  type ProviderInteractionMode,
  type RuntimeMode,
  RuntimeRequestId,
  type GitActionProgressEvent,
  type OrchestrationMessageContext,
  type GitRunStackedActionResult,
  type GitStackedAction,
  type FilesystemBrowseResult,
  type SourceControlCloneRepositoryResult,
  type SourceControlDiscoveryResult,
  type SourceControlProviderKind,
  type SourceControlRepositoryInfo,
  type TerminalAttachStreamEvent,
  type TerminalMetadataStreamEvent,
  type TerminalRestartInput,
  type ThreadId,
  ThreadId as ThreadIdSchema,
  ThreadMoveDestination,
  type ThreadMoveInput,
  ThreadMoveResult,
  ThreadPlacement,
  type ThreadPlacementInput,
  TrimmedNonEmptyString,
  type UploadChatImageAttachment,
  type ServerConfig,
  type VcsListRefsResult,
  type VcsStatusLocalResult,
  type VcsStatusRemoteResult,
  type VcsStatusResult,
  type VcsSwitchRefResult,
  WS_METHODS,
} from "@hal-c2/contracts";
import {
  EnvironmentSupervisor,
  type PreparedConnection,
  PrimaryConnectionTarget,
  type SupervisorConnectionState,
} from "@hal-c2/client-runtime/connection";
import {
  archiveThread as archiveThreadOp,
  createProject as createProjectOp,
  deleteThread as deleteThreadOp,
  interruptThreadTurn,
  respondToThreadApproval,
  respondToThreadUserInput,
  setThreadInteractionMode,
  setThreadRuntimeMode,
  settleThread as settleThreadOp,
  snoozeThread as snoozeThreadOp,
  unsnoozeThread as unsnoozeThreadOp,
  startThreadTurn,
  revertThreadCheckpoint,
  stopThreadSession,
  unarchiveThread as unarchiveThreadOp,
  unsettleThread as unsettleThreadOp,
  updateThreadMetadata,
} from "@hal-c2/client-runtime/operations";
import { inferProjectTitleFromPath } from "@hal-c2/client-runtime/state/projects";
import {
  mcMembers,
  mcRequest,
  remoteHttpClientLayer,
  request,
  layerWithOptions,
  RpcSessionFactory,
  runStream,
  subscribe,
} from "@hal-c2/client-runtime/rpc";
import { ShellSnapshotLoader } from "@hal-c2/client-runtime/state/shell";
import type { RpcSession } from "@hal-c2/client-runtime/rpc";
import { buildTemporaryWorktreeBranchName } from "@hal-c2/shared/git";

import { makeFeatureClient, type TuiFeatureClient } from "./featureClient.ts";
import { mergeVcsStatus } from "./gitActions.logic.ts";

import { flattenModelOptions, type ModelOption } from "./models.ts";
import { EnvironmentCacheStore } from "@hal-c2/client-runtime/platform";
import {
  type EnvironmentShellState,
  makeEnvironmentShellState,
} from "@hal-c2/client-runtime/state/shell";
import {
  boundedThreadSnapshotLoaderLayer,
  type EnvironmentThreadState,
  makeEnvironmentThreadState,
  ThreadHistoryController,
  threadHistoryControllerLayer,
  ThreadSnapshotLoader,
} from "@hal-c2/client-runtime/state/threads";
import type { ThreadHistoryMeta } from "@hal-c2/client-runtime/state/threads";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Logger from "effect/Logger";
import * as ManagedRuntime from "effect/ManagedRuntime";
import * as Option from "effect/Option";
import * as References from "effect/References";
import * as Schema from "effect/Schema";
import * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";
import * as NodeServices from "@effect/platform-node/NodeServices";
import type { HttpClient } from "effect/unstable/http";
import * as Socket from "effect/unstable/socket/Socket";

import { createAttachmentImageCache } from "./attachmentImages.ts";
import { makeTuiSettingsClient, type TuiSettingsClient } from "./settingsClient.ts";
import type { ImagePreview } from "@hal-c2/opentui-image";
import {
  presentTuiShell,
  presentTuiThread,
  type TuiShellSnapshot as OrchestrationShellSnapshot,
} from "./orchestrationV2Adapter.ts";

/** Paging state for a live thread's older history, as the chat view renders it. */
export interface TuiThreadPage {
  readonly hasMore: boolean;
  readonly loadingOlder: boolean;
}

function historyToPage(history: ThreadHistoryMeta): TuiThreadPage {
  return { hasMore: history.hasMoreHistory, loadingOlder: history.loading };
}

/**
 * Connection inputs the entry provides from `mcDiscovery.ts`: the MC's access
 * token or a paired session, and `mintSocketUrl`, which returns a
 * freshly-ticketed `ws(s)://…/ws?wsTicket=…` URL on every (re)connect.
 */
export interface TuiOptions {
  /** Origin of the MC, e.g. `http://127.0.0.1:5733`. */
  readonly origin: string;
  /** Long-lived bearer token used for HTTP authorization on the connection. */
  readonly bearerToken: string;
  /** Mint a fresh, fully-formed websocket URL (with a short-lived ticket). */
  readonly mintSocketUrl: () => Promise<string>;
  /** File the Effect runtime logs to (Ink owns stdout, so never log there). */
  readonly logPath: string;
  /** Pause between a dropped connection and the next attempt (2 seconds). */
  readonly reconnectDelay?: Duration.Input;
  /** The MC's environment id from its descriptor; a protocol-3 session addresses it. */
  readonly environmentId: string;
  /** The MC's wire protocol from its descriptor. */
  readonly orchestrationProtocolVersion?: number | undefined;
}

const TUI_LABEL = "HAL-C2";
const RECONNECT_DELAY = Duration.seconds(2);

/** Trim a free-text field, returning a branded value or null when empty. */
const toNullableTrimmed = (value: string | null) => {
  const trimmed = value?.trim() ?? "";
  return trimmed.length > 0 ? TrimmedNonEmptyString.make(trimmed) : null;
};

export interface TuiCreateThreadInput {
  readonly projectId: ProjectId;
  readonly projectCwd: string;
  readonly title: string;
  readonly modelSelection: ModelSelection;
  readonly firstMessage: string;
  readonly attachments: ReadonlyArray<UploadChatImageAttachment>;
  readonly runtimeMode: RuntimeMode;
  readonly interactionMode: ProviderInteractionMode;
  readonly branch: string | null;
  readonly worktreePath: string | null;
  readonly createWorktree: boolean;
  readonly startFromOrigin: boolean;
}

export function buildThreadReplyTurn(input: {
  readonly thread: Pick<OrchestrationThread, "id" | "runtimeMode" | "interactionMode">;
  readonly messageId: MessageId;
  readonly text: string;
  readonly attachments: ReadonlyArray<UploadChatImageAttachment>;
  readonly modelSelection?: ModelSelection;
  readonly context?: OrchestrationMessageContext;
}) {
  return {
    threadId: input.thread.id,
    message: {
      messageId: input.messageId,
      role: "user" as const,
      text: input.text,
      attachments: [...input.attachments],
      ...(input.context ? { context: input.context } : {}),
    },
    runtimeMode: input.thread.runtimeMode,
    interactionMode: input.thread.interactionMode,
    ...(input.modelSelection ? { modelSelection: input.modelSelection } : {}),
  };
}

/** Build the web-compatible, server-cleaned-up bootstrap for a thread's first turn. */
export function buildThreadCreationBootstrap(
  input: TuiCreateThreadInput,
  createdAt: string,
  worktreeBranch: string | null,
) {
  if (input.createWorktree && (!input.branch?.trim() || !worktreeBranch?.trim())) {
    throw new Error("A base branch is required to create a worktree");
  }
  return {
    createThread: {
      projectId: input.projectId,
      title: TrimmedNonEmptyString.make(input.title),
      modelSelection: input.modelSelection,
      runtimeMode: input.runtimeMode,
      interactionMode: input.interactionMode,
      branch: toNullableTrimmed(input.branch),
      worktreePath: toNullableTrimmed(input.worktreePath),
      createdAt,
    },
    ...(input.createWorktree && input.branch && worktreeBranch
      ? {
          prepareWorktree: {
            projectCwd: TrimmedNonEmptyString.make(input.projectCwd),
            baseBranch: TrimmedNonEmptyString.make(input.branch),
            branch: TrimmedNonEmptyString.make(worktreeBranch),
            ...(input.startFromOrigin ? { startFromOrigin: true } : {}),
          },
          runSetupScript: true,
        }
      : {}),
  };
}

const CONNECTING_STATE: SupervisorConnectionState = {
  desired: true,
  network: "online",
  phase: "connecting",
  stage: "opening",
  attempt: 1,
  generation: 0,
  lastFailure: null,
  retryAt: null,
};

const CONNECTED_STATE: SupervisorConnectionState = {
  ...CONNECTING_STATE,
  phase: "connected",
  stage: null,
};

/**
 * A minimal {@link EnvironmentSupervisor} for the TUI. It maintains a single
 * connection to the MC, re-minting a fresh websocket URL on every (re)connect
 * attempt via the host-provided `mintSocketUrl`. We reuse the heavy
 * `client-runtime` RPC client + reducers but skip its multi-environment relay
 * machinery, which the TUI does not need.
 */
export const makeTuiSupervisor = (options: Omit<TuiOptions, "logPath">) =>
  Effect.gen(function* () {
    const factory = yield* RpcSessionFactory;
    const { origin } = options;
    const environmentId = EnvironmentId.make(options.environmentId);

    const target = new PrimaryConnectionTarget({
      environmentId,
      label: TUI_LABEL,
      httpBaseUrl: origin,
      wsBaseUrl: origin,
    });

    const sessionRef = yield* SubscriptionRef.make<Option.Option<RpcSession>>(Option.none());
    const stateRef = yield* SubscriptionRef.make<SupervisorConnectionState>(CONNECTING_STATE);
    const preparedRef = yield* SubscriptionRef.make<Option.Option<PreparedConnection>>(
      Option.none(),
    );

    const runConnection = Effect.gen(function* () {
      const socketUrl = yield* Effect.tryPromise({
        try: () => options.mintSocketUrl(),
        catch: (cause) => cause,
      });
      const prepared: PreparedConnection = {
        environmentId,
        label: TUI_LABEL,
        httpBaseUrl: origin,
        socketUrl,
        httpAuthorization: { _tag: "Bearer", token: options.bearerToken },
        target,
        ...(options.orchestrationProtocolVersion === undefined
          ? {}
          : { orchestrationProtocolVersion: options.orchestrationProtocolVersion }),
      };
      yield* SubscriptionRef.set(preparedRef, Option.some(prepared));
      const session = yield* factory.connect(prepared);
      yield* session.ready;
      yield* SubscriptionRef.set(sessionRef, Option.some(session));
      yield* SubscriptionRef.set(stateRef, CONNECTED_STATE);
      // `closed` fails when the socket drops; that unwinds the scope below.
      return yield* session.closed;
    });

    const loop = Effect.gen(function* () {
      for (;;) {
        yield* Effect.scoped(runConnection).pipe(Effect.ignore);
        yield* SubscriptionRef.set(sessionRef, Option.none());
        yield* SubscriptionRef.set(stateRef, CONNECTING_STATE);
        yield* Effect.sleep(options.reconnectDelay ?? RECONNECT_DELAY);
      }
    });

    yield* Effect.forkScoped(loop);

    return EnvironmentSupervisor.of({
      target,
      state: stateRef,
      session: sessionRef,
      prepared: preparedRef,
      connect: Effect.void,
      disconnect: Effect.void,
      retryNow: Effect.void,
    });
  });

/**
 * Maps supervisor states to the phase the UI shows: "connecting" until the first
 * connection, "reconnecting" whenever it is lost after that.
 */
export function connectionPhases(): (state: SupervisorConnectionState) => TuiConnectionPhase {
  let connectedOnce = false;
  return (state) => {
    if (state.phase === "connected") {
      connectedOnce = true;
      return "connected";
    }
    return connectedOnce ? "reconnecting" : "connecting";
  };
}

/** Effect-side logger that never touches stdout (Ink owns the screen). */
const fileLoggerLayer = (logPath: string) =>
  Logger.layer([
    Logger.formatJson.pipe(
      Logger.map((line: string) => {
        try {
          NodeFS.appendFileSync(logPath, `${line}\n`);
        } catch {
          // Logging must never crash the UI.
        }
      }),
    ),
  ]);

export type TuiRuntime = ManagedRuntime.ManagedRuntime<
  | EnvironmentSupervisor
  | Crypto.Crypto
  | EnvironmentCacheStore
  | ThreadSnapshotLoader
  | ShellSnapshotLoader
  | ThreadHistoryController
  | HttpClient.HttpClient,
  never
>;

/**
 * An in-memory {@link EnvironmentCacheStore}. The web persists the orchestration
 * cache to IndexedDB; the Bun TUI subprocess has no cache dir, so we back it with
 * a `Map`. That still gives within-session persistence — an LRU-evicted thread
 * re-opens instantly from this cache before its live subscription re-establishes.
 */
const inMemoryCacheStoreLayer = Layer.sync(EnvironmentCacheStore, () => {
  // Threads are cached as detail SNAPSHOTS ({ snapshotSequence, thread }) so a
  // cache hit can resume live sync from the right projection sequence.
  const threads = new Map<string, OrchestrationV2ThreadDetailSnapshot>();
  const shells = new Map<string, OrchestrationV2ShellSnapshot>();
  const serverConfigs = new Map<string, ServerConfig>();
  const vcsRefs = new Map<string, VcsListRefsResult>();
  const threadKey = (environmentId: string, threadId: string) =>
    `${environmentId}\u0000${threadId}`;
  return EnvironmentCacheStore.of({
    loadShell: (environmentId) => Effect.succeed(Option.fromUndefinedOr(shells.get(environmentId))),
    saveShell: (environmentId, snapshot) =>
      Effect.sync(() => {
        shells.set(environmentId, snapshot);
      }),
    loadThread: (environmentId, threadId) =>
      Effect.succeed(Option.fromUndefinedOr(threads.get(threadKey(environmentId, threadId)))),
    saveThread: (environmentId, snapshot) =>
      Effect.sync(() => {
        threads.set(threadKey(environmentId, snapshot.projection.thread.id), snapshot);
      }),
    removeThread: (environmentId, threadId) =>
      Effect.sync(() => {
        threads.delete(threadKey(environmentId, threadId));
      }),
    loadServerConfig: (environmentId) =>
      Effect.succeed(Option.fromUndefinedOr(serverConfigs.get(environmentId))),
    saveServerConfig: (environmentId, config) =>
      Effect.sync(() => {
        serverConfigs.set(environmentId, config);
      }),
    loadVcsRefs: (environmentId, cwd) =>
      Effect.succeed(Option.fromUndefinedOr(vcsRefs.get(`${environmentId}\u0000${cwd}`))),
    saveVcsRefs: (environmentId, cwd, refs) =>
      Effect.sync(() => {
        vcsRefs.set(`${environmentId}\u0000${cwd}`, refs);
      }),
    removeVcsRefs: (environmentId, cwd) =>
      Effect.sync(() => {
        vcsRefs.delete(`${environmentId}\u0000${cwd}`);
      }),
    clearVcsRefs: (environmentId) =>
      Effect.sync(() => {
        for (const key of vcsRefs.keys()) {
          if (key.startsWith(`${environmentId}\u0000`)) vcsRefs.delete(key);
        }
      }),
    clear: (environmentId) =>
      Effect.sync(() => {
        shells.delete(environmentId);
        serverConfigs.delete(environmentId);
        for (const key of vcsRefs.keys()) {
          if (key.startsWith(`${environmentId}\u0000`)) vcsRefs.delete(key);
        }
        for (const key of threads.keys()) {
          if (key.startsWith(`${environmentId}\u0000`)) threads.delete(key);
        }
      }),
  });
});

/**
 * Assemble a self-contained runtime that provides {@link EnvironmentSupervisor}
 * and {@link Crypto.Crypto} so the UI can issue RPC requests and subscriptions
 * without knowing anything about Effect layers.
 */
export function buildTuiRuntime(options: TuiOptions): TuiRuntime {
  const services = Layer.mergeAll(
    NodeServices.layer,
    Layer.succeed(References.MinimumLogLevel, "Error"),
    fileLoggerLayer(options.logPath),
  );

  const rpcLayer = layerWithOptions({}).pipe(Layer.provide(Socket.layerWebSocketConstructorGlobal));

  const supervisorLayer = Layer.effect(EnvironmentSupervisor, makeTuiSupervisor(options)).pipe(
    Layer.provideMerge(rpcLayer),
    Layer.provideMerge(services),
  );

  // The first snapshot can fall back to the socket, but older thread pages are
  // HTTP-only. Keep the bounded thread loader plus the history controller so
  // long conversations can page past the initial window. The shell has no
  // paging, so it keeps using the socket-embedded snapshot.
  const snapshotLoaders = Layer.mergeAll(
    boundedThreadSnapshotLoaderLayer,
    threadHistoryControllerLayer,
    Layer.succeed(ShellSnapshotLoader, ShellSnapshotLoader.of({ load: () => Effect.succeedNone })),
  ).pipe(Layer.provideMerge(remoteHttpClientLayer(globalThis.fetch)));

  const runtimeLayer = Layer.mergeAll(supervisorLayer, inMemoryCacheStoreLayer, snapshotLoaders);

  return ManagedRuntime.make(runtimeLayer) as unknown as TuiRuntime;
}

// ── Imperative client surface consumed by the UI components ────────────────

/** Where the loopback connection is: first connect, live, or retrying after a drop. */
export type TuiConnectionPhase = "connecting" | "connected" | "reconnecting";

export interface TuiClient extends TuiFeatureClient, TuiSettingsClient {
  readonly hostPlatform: NodeJS.Platform;
  /** Live connection phase (emits the current one first). Returns an unsubscribe fn. */
  readonly subscribeConnection: (onPhase: (phase: TuiConnectionPhase) => void) => () => void;
  /** Told when a machine of this machine's cluster joins, leaves, goes offline or comes back. */
  readonly subscribeCluster: (onChange: () => void) => () => void;
  /**
   * Says which project the draft on screen is in, null once it closes. In a
   * cluster a checkout path several machines have is then read on that
   * project's machine (clusterClient.ts).
   */
  readonly viewProject: (projectId: string | null) => void;
  readonly browseFilesystem: (partialPath: string, cwd?: string) => Promise<FilesystemBrowseResult>;
  readonly discoverSourceControl: () => Promise<SourceControlDiscoveryResult>;
  readonly lookupRepository: (
    provider: SourceControlProviderKind,
    repository: string,
  ) => Promise<SourceControlRepositoryInfo>;
  /** This machine's cluster: who is in it, an invite for another machine, joining, removing. */
  readonly clusterStatus: () => Promise<ClusterStatus>;
  readonly clusterInvite: (input: ClusterInviteInput) => Promise<ClusterInvite>;
  readonly clusterJoin: (link: string) => Promise<ClusterStatus>;
  readonly clusterRemove: (id: string) => Promise<ClusterStatus>;
  /** The other machines of the cluster a thread could move to, and their projects. */
  readonly moveDestinations: (threadId: string) => Promise<ReadonlyArray<ThreadMoveDestination>>;
  /**
   * Move a thread to another machine. Besides `moved` the MC may answer `confirm`
   * (ask again with `confirmed`) or `choose_project` (ask again with a `projectId`).
   */
  readonly moveThread: (input: ThreadMoveInput) => Promise<ThreadMoveResult>;
  /**
   * Where the MC would start a new thread the user is starting in a project of
   * one of the cluster's machines: that same pair, or another machine's checkout.
   */
  readonly placeThread: (input: ThreadPlacementInput) => Promise<ThreadPlacement>;
  /** The MC's settings document, and the version to write it back at. */
  readonly readSettings: () => Promise<McSettings>;
  /**
   * Replace the MC's settings document. False when it changed since `version`
   * was read: read it again and reapply the edit.
   */
  readonly writeSettings: (settings: McSettings["settings"], version: number) => Promise<boolean>;
  readonly cloneRepository: (
    remoteUrl: string,
    destinationPath: string,
  ) => Promise<SourceControlCloneRepositoryResult>;
  /** Live list of every project + thread. Returns an unsubscribe fn. */
  readonly subscribeShell: (
    onSnapshot: (snapshot: OrchestrationShellSnapshot) => void,
  ) => () => void;
  /** Live detail (messages, session, activities) for one thread. */
  readonly subscribeThread: (
    threadId: ThreadId,
    onThread: (thread: OrchestrationThread, page: TuiThreadPage) => void,
  ) => () => void;
  /** Request the next bounded page of older turns for a live thread. */
  readonly loadOlderThreadTurns: (threadId: ThreadId) => boolean;
  /** Last-seen detail for a thread (from the warm cache), or null. Synchronous. */
  readonly peekThread: (threadId: ThreadId) => OrchestrationThread | null;
  /** Attach to a thread terminal; raw PTY bytes are delivered via onEvent. */
  readonly subscribeTerminal: (
    input: {
      readonly threadId: ThreadId;
      readonly terminalId: string;
      readonly cwd: string;
      readonly worktreePath: string | null;
      readonly cols: number;
      readonly rows: number;
      /** What a shell started by this attach finds in its environment. */
      readonly env?: Readonly<Record<string, string>>;
    },
    onEvent: (event: TerminalAttachStreamEvent) => void,
  ) => () => void;
  /** Start the terminal's shell (again, when it has ended) so a command can be written to it. */
  readonly terminalOpen: (input: {
    readonly threadId: ThreadId;
    readonly terminalId: string;
    readonly cwd: string;
    readonly worktreePath: string | null;
    readonly cols: number;
    readonly rows: number;
    readonly env?: Readonly<Record<string, string>>;
  }) => Promise<void>;
  readonly sendReply: (
    thread: Pick<OrchestrationThread, "id" | "runtimeMode" | "interactionMode">,
    text: string,
    attachments?: ReadonlyArray<UploadChatImageAttachment>,
    modelSelection?: ModelSelection,
    /** The typed payloads behind the message's context references (terminal output, diff notes). */
    context?: OrchestrationMessageContext,
  ) => Promise<void>;
  /** Register a local workspace as a project and return its generated id. */
  readonly createProject: (workspaceRoot: string) => Promise<ProjectId>;
  readonly createThread: (input: TuiCreateThreadInput) => Promise<ThreadId>;
  readonly implementPlan: (
    thread: Pick<OrchestrationThread, "id" | "runtimeMode">,
    planId: string,
  ) => Promise<void>;
  readonly interrupt: (threadId: ThreadId) => Promise<void>;
  readonly approve: (
    threadId: ThreadId,
    requestId: string,
    decision: ProviderApprovalDecision,
  ) => Promise<void>;
  readonly respondUserInput: (
    threadId: ThreadId,
    requestId: string,
    answers: Record<string, string | string[]>,
  ) => Promise<void>;
  readonly setRuntimeMode: (threadId: ThreadId, mode: RuntimeMode) => Promise<void>;
  readonly setInteractionMode: (threadId: ThreadId, mode: ProviderInteractionMode) => Promise<void>;
  readonly renameThread: (threadId: ThreadId, title: string) => Promise<void>;
  readonly archiveThread: (threadId: ThreadId) => Promise<void>;
  readonly unarchiveThread: (threadId: ThreadId) => Promise<void>;
  readonly deleteThread: (threadId: ThreadId) => Promise<void>;
  /** Park the thread in the sidebar's Settled shelf. The server rejects it while the thread still needs attention. */
  readonly settleThread: (threadId: ThreadId) => Promise<void>;
  /** Return a settled thread to Active, pinned there until real activity clears the pin server-side. */
  readonly unsettleThread: (threadId: ThreadId) => Promise<void>;
  /** Hide the thread until `snoozedUntil` (ISO); the server refuses one that waits on the user. */
  readonly snoozeThread: (threadId: ThreadId, snoozedUntil: string) => Promise<void>;
  readonly unsnoozeThread: (threadId: ThreadId) => Promise<void>;
  readonly stopSession: (threadId: ThreadId) => Promise<void>;
  readonly revertCheckpoint: (threadId: ThreadId, turnCount: number) => Promise<void>;
  /** Live git status for a worktree (folded from the snapshot/local/remote stream). */
  readonly subscribeVcsStatus: (
    cwd: string,
    onStatus: (status: VcsStatusResult) => void,
  ) => () => void;
  /**
   * Run a stacked git action (commit/push/create_pr/…); resolves with the
   * server's result (null if the stream ended without one) when it finishes.
   */
  readonly runGitStackedAction: (
    input: {
      readonly cwd: string;
      readonly action: GitStackedAction;
      readonly commitMessage?: string;
      readonly featureBranch?: boolean;
    },
    /** Sees each phase, hook and line of hook output as the server reports it. */
    onProgress?: (event: GitActionProgressEvent) => void,
  ) => Promise<GitRunStackedActionResult | null>;
  /** Pull the worktree's branch from its upstream. */
  readonly runGitPull: (cwd: string) => Promise<void>;
  /** Fetch the unified diff for the turn that produced the given checkpoint. */
  readonly getTurnDiff: (threadId: ThreadId, toTurnCount: number) => Promise<string>;
  /** Fetch the cumulative diff of all changes in the thread up to `toTurnCount`. */
  readonly getFullThreadDiff: (threadId: ThreadId, toTurnCount: number) => Promise<string>;
  /** The selectable models reported by the server's configured providers. */
  readonly listModels: () => Promise<ModelOption[]>;
  /** Current server settings, including new-thread workspace defaults. */
  readonly getServerConfig: () => Promise<ServerConfig>;
  /** Git refs available as base branches for a project's new worktree. */
  readonly listRefs: (cwd: string) => Promise<VcsListRefsResult>;
  /** Switch the selected checkout to a ref before creating a thread in it. */
  readonly switchRef: (cwd: string, refName: string) => Promise<VcsSwitchRefResult>;
  readonly terminalWrite: (threadId: ThreadId, terminalId: string, data: string) => Promise<void>;
  readonly terminalResize: (
    threadId: ThreadId,
    terminalId: string,
    cols: number,
    rows: number,
  ) => Promise<void>;
  /** Clear one terminal's persisted history and visible buffer. */
  readonly terminalClear: (threadId: ThreadId, terminalId: string) => Promise<void>;
  /** Restart one terminal session in-place, preserving its tab identity. */
  readonly terminalRestart: (input: TerminalRestartInput) => Promise<void>;
  /** Close one terminal session (and its history) for a thread. */
  readonly terminalClose: (threadId: ThreadId, terminalId: string) => Promise<void>;
  /** List live and persisted terminal identities retained for a thread. */
  readonly listTerminalIds: (threadId: ThreadId) => Promise<ReadonlyArray<string>>;
  /**
   * Subscribe to the environment's terminal-metadata stream so the UI can
   * discover sessions it didn't open itself (agent-spawned, web-created, or
   * from a prior run). Emits a snapshot, then upsert/remove deltas.
   */
  readonly subscribeTerminalMetadata: (
    onEvent: (event: TerminalMetadataStreamEvent) => void,
  ) => () => void;
  /** Resolve a message image attachment to an absolute URL, or null on failure. */
  readonly getAttachmentUrl: (attachmentId: string) => Promise<string | null>;
  /** Download and decode a bounded native-image preview for a resolved attachment URL. */
  readonly getAttachmentImage: (
    attachmentId: string,
    resolvedUrl: string,
  ) => Promise<ImagePreview | null>;
  /** List the workspace's files + directories (bounded index) for the file browser. */
  readonly listEntries: (cwd: string) => Promise<ReadonlyArray<ProjectEntry>>;
  /** Read a workspace file's contents, or null on failure. */
  readonly readFile: (cwd: string, relativePath: string) => Promise<string | null>;
  /** Read a bounded workspace file as base64 for attachment preparation. */
  readonly readFileBase64: (
    cwd: string,
    relativePath: string,
  ) => Promise<Pick<ProjectReadFileResult, "contents" | "byteLength" | "truncated"> | null>;
  readonly dispose: () => Promise<void>;
}

// The MC's own methods (`hal-c2.*`) are outside the RPC contract, so their
// answers are decoded here.
const decodeMoveDestinations = Schema.decodeUnknownSync(Schema.Array(ThreadMoveDestination));
const decodeMoveResult = Schema.decodeUnknownSync(ThreadMoveResult);
const decodePlacement = Schema.decodeUnknownSync(ThreadPlacement);

/** The MC's settings document as stored: a client edits the keys it knows and keeps the rest. */
const McSettings = Schema.Struct({
  settings: Schema.Record(Schema.String, Schema.Unknown),
  version: Schema.Int,
});
export type McSettings = typeof McSettings.Type;
const decodeSettings = Schema.decodeUnknownSync(McSettings);

/** The MC refused a settings write because another client wrote first. */
const isStaleSettings = (error: unknown): boolean =>
  (error as { readonly detail?: { readonly _tag?: unknown } } | null)?.detail?._tag ===
  "StaleSettings";

const randomUuid = Effect.gen(function* () {
  const crypto = yield* Crypto.Crypto;
  return yield* crypto.randomUUIDv4.pipe(Effect.orDie);
});

/** A long-lived SubscriptionRef kept warm in its own scope until `close()`. */
interface WarmSubscriptionRef<S> {
  readonly ref: Promise<SubscriptionRef.SubscriptionRef<S>>;
  readonly close: () => void;
  order: number;
}

/** Number of recently-viewed threads whose live state we keep warm (LRU). */
const THREAD_WARM_LIMIT = 8;

export function makeTuiClient(runtime: TuiRuntime, origin = ""): TuiClient {
  const attachmentImages = createAttachmentImageCache();
  // oxlint-disable-next-line hal-c2/no-global-process-runtime -- @hal-c2/shared/hostProcess imports node:sea, which the Bun-run TUI lacks.
  const hostPlatform = process.platform;
  const drainStreamUntilUnsubscribe = <A>(
    stream: Stream.Stream<A, unknown, EnvironmentSupervisor>,
  ): (() => void) => {
    const fiber = runtime.runFork(Stream.runDrain(stream));
    return () => {
      runtime.runFork(Fiber.interrupt(fiber));
    };
  };

  // ── Warm state registry (the web's caching engine) ──────────────────────────
  //
  // `makeEnvironmentThreadState`/`makeEnvironmentShellState` build a SubscriptionRef
  // that loads the cache, subscribes to the socket, applies referentially-stable
  // deltas, persists on close, and re-syncs on reconnect. We run each in a scope we
  // keep open (Effect.never) so it stays warm; closing the scope interrupts it and
  // flushes the last value to the in-memory cache.

  const startWarmSubscriptionRef = <S>(
    build: Effect.Effect<
      SubscriptionRef.SubscriptionRef<S>,
      never,
      | EnvironmentSupervisor
      | EnvironmentCacheStore
      | ThreadSnapshotLoader
      | ShellSnapshotLoader
      | Scope.Scope
    >,
  ): WarmSubscriptionRef<S> => {
    let resolveRef: (ref: SubscriptionRef.SubscriptionRef<S>) => void = () => {};
    const ref = new Promise<SubscriptionRef.SubscriptionRef<S>>((resolve) => {
      resolveRef = resolve;
    });
    const fiber = runtime.runFork(
      Effect.scoped(
        Effect.gen(function* () {
          const subscriptionRef = yield* build;
          resolveRef(subscriptionRef);
          return yield* Effect.never;
        }),
      ),
    );
    return {
      ref,
      close: () => {
        runtime.runFork(Fiber.interrupt(fiber));
      },
      order: 0,
    };
  };

  /** Stream a warm ref's changes into a callback; returns an unsubscribe. */
  const subscribeToWarmRef = <S>(
    entry: WarmSubscriptionRef<S>,
    onValue: (value: S) => void,
  ): (() => void) => {
    let cancelled = false;
    let fiber: Fiber.Fiber<void, unknown> | null = null;
    void entry.ref.then((subscriptionRef) => {
      if (cancelled) return;
      fiber = runtime.runFork(
        SubscriptionRef.changes(subscriptionRef).pipe(
          Stream.runForEach((value) => Effect.sync(() => onValue(value))),
        ),
      );
    });
    return () => {
      cancelled = true;
      if (fiber) runtime.runFork(Fiber.interrupt(fiber));
    };
  };

  const warmThreads = new Map<string, WarmSubscriptionRef<EnvironmentThreadState>>();
  // Last-seen detail per thread, kept in sync by the UI subscription, so a
  // re-select can paint instantly (no blank) before the fresh value streams in.
  const latestThreads = new Map<string, OrchestrationThread>();
  let warmOrder = 0;
  let shellWarm: WarmSubscriptionRef<EnvironmentShellState> | null = null;
  // Monotonic id correlating a stacked-git-action's progress stream on the server.
  let gitActionSeq = 0;

  /** Close a warm thread's scope and drop its cached snapshot. */
  const evictThread = (key: string) => {
    warmThreads.get(key)?.close();
    warmThreads.delete(key);
    latestThreads.delete(key);
  };

  const acquireThread = (threadId: ThreadId): WarmSubscriptionRef<EnvironmentThreadState> => {
    const key = threadId as string;
    const existing = warmThreads.get(key);
    if (existing) {
      existing.order = ++warmOrder;
      return existing;
    }
    // Build the warm thread state and keep it live in its own scope. An internal
    // watcher keeps `latestThreads` fresh (so peekThread is instant) and evicts the
    // entry if the thread is deleted — otherwise makeEnvironmentThreadState retries
    // its now-failing subscription every 250ms forever and hammers the server.
    let resolveRef: (
      ref: SubscriptionRef.SubscriptionRef<EnvironmentThreadState>,
    ) => void = () => {};
    const ref = new Promise<SubscriptionRef.SubscriptionRef<EnvironmentThreadState>>((resolve) => {
      resolveRef = resolve;
    });
    const fiber = runtime.runFork(
      Effect.scoped(
        Effect.gen(function* () {
          const subscriptionRef = yield* makeEnvironmentThreadState(threadId);
          resolveRef(subscriptionRef);
          yield* SubscriptionRef.changes(subscriptionRef).pipe(
            Stream.runForEach((state) =>
              Effect.sync(() => {
                if (Option.isSome(state.data)) {
                  latestThreads.set(key, presentTuiThread(state.data.value));
                }
                if (state.status === "deleted") evictThread(key);
              }),
            ),
          );
        }),
      ),
    );
    const entry: WarmSubscriptionRef<EnvironmentThreadState> = {
      ref,
      close: () => {
        runtime.runFork(Fiber.interrupt(fiber));
      },
      order: ++warmOrder,
    };
    warmThreads.set(key, entry);
    // Evict the least-recently-used warm thread beyond the cap (never the new one).
    if (warmThreads.size > THREAD_WARM_LIMIT) {
      let oldestKey: string | null = null;
      let oldestOrder = Number.POSITIVE_INFINITY;
      for (const [candidateKey, candidate] of warmThreads) {
        if (candidate.order < oldestOrder) {
          oldestOrder = candidate.order;
          oldestKey = candidateKey;
        }
      }
      if (oldestKey !== null && oldestKey !== key) evictThread(oldestKey);
    }
    return entry;
  };

  const disposeWarm = () => {
    for (const entry of warmThreads.values()) entry.close();
    warmThreads.clear();
    latestThreads.clear();
    shellWarm?.close();
    shellWarm = null;
  };

  return {
    ...makeFeatureClient(runtime),
    ...makeTuiSettingsClient(runtime),
    hostPlatform,
    browseFilesystem: (partialPath, cwd) =>
      runtime.runPromise(
        request(WS_METHODS.filesystemBrowse, {
          partialPath: TrimmedNonEmptyString.make(partialPath),
          ...(cwd ? { cwd: TrimmedNonEmptyString.make(cwd) } : {}),
        }),
      ),
    discoverSourceControl: () =>
      runtime.runPromise(request(WS_METHODS.serverDiscoverSourceControl, {})),
    lookupRepository: (provider, repository) =>
      runtime.runPromise(
        request(WS_METHODS.sourceControlLookupRepository, {
          provider,
          repository: TrimmedNonEmptyString.make(repository),
        }),
      ),
    clusterStatus: () => runtime.runPromise(request(WS_METHODS.clusterStatus, {})),
    clusterInvite: (input) => runtime.runPromise(request(WS_METHODS.clusterInvite, input)),
    clusterJoin: (link) => runtime.runPromise(request(WS_METHODS.clusterJoin, { link })),
    clusterRemove: (id) => runtime.runPromise(request(WS_METHODS.clusterRemove, { id })),
    moveDestinations: (threadId) =>
      runtime
        .runPromise(mcRequest("hal-c2.moveDestinations", { threadId }))
        .then(decodeMoveDestinations),
    moveThread: (input) =>
      runtime.runPromise(mcRequest("hal-c2.moveThread", input)).then(decodeMoveResult),
    placeThread: (input) =>
      runtime.runPromise(mcRequest("hal-c2.placeThread", input)).then(decodePlacement),
    readSettings: () =>
      runtime.runPromise(mcRequest("hal-c2.readSettings", {})).then(decodeSettings),
    writeSettings: (settings, version) =>
      runtime.runPromise(mcRequest("hal-c2.writeSettings", { settings, version })).then(
        () => true,
        (error: unknown) => {
          if (isStaleSettings(error)) return false;
          throw error;
        },
      ),
    cloneRepository: (remoteUrl, destinationPath) =>
      runtime.runPromise(
        request(WS_METHODS.sourceControlCloneRepository, {
          remoteUrl: TrimmedNonEmptyString.make(remoteUrl),
          destinationPath: TrimmedNonEmptyString.make(destinationPath),
        }),
      ),
    subscribeConnection: (onPhase) => {
      const toPhase = connectionPhases();
      return drainStreamUntilUnsubscribe(
        Stream.unwrap(
          Effect.gen(function* () {
            const supervisor = yield* EnvironmentSupervisor;
            return SubscriptionRef.changes(supervisor.state);
          }),
        ).pipe(Stream.tap((state) => Effect.sync(() => onPhase(toPhase(state))))),
      );
    },
    subscribeCluster: (onChange) =>
      drainStreamUntilUnsubscribe(mcMembers.pipe(Stream.tap(() => Effect.sync(onChange)))),
    // One machine: every path is its own.
    viewProject: () => {},
    subscribeShell: (onSnapshot) => {
      shellWarm ??= startWarmSubscriptionRef(makeEnvironmentShellState());
      return subscribeToWarmRef(shellWarm, (state) => {
        if (Option.isSome(state.snapshot)) onSnapshot(presentTuiShell(state.snapshot.value));
      });
    },

    subscribeThread: (threadId, onThread) => {
      const entry = acquireThread(threadId);
      return subscribeToWarmRef(entry, (state) => {
        if (Option.isSome(state.data)) {
          onThread(presentTuiThread(state.data.value), historyToPage(state.history));
        }
      });
    },

    loadOlderThreadTurns: (threadId) => {
      runtime.runFork(
        Effect.gen(function* () {
          const controller = yield* ThreadHistoryController;
          const supervisor = yield* EnvironmentSupervisor;
          return yield* controller.loadEarlier(supervisor.target.environmentId, threadId);
        }),
      );
      return true;
    },

    peekThread: (threadId) => latestThreads.get(threadId as string) ?? null,

    subscribeTerminal: (input, onEvent) => {
      const stream = subscribe(WS_METHODS.terminalAttach, {
        threadId: input.threadId,
        terminalId: input.terminalId,
        cwd: input.cwd,
        worktreePath: input.worktreePath,
        cols: input.cols,
        rows: input.rows,
        ...(input.env ? { env: input.env } : {}),
        restartIfNotRunning: true,
      }).pipe(Stream.tap((event) => Effect.sync(() => onEvent(event))));
      return drainStreamUntilUnsubscribe(stream);
    },

    sendReply: (thread, text, attachments = [], modelSelection, context) =>
      runtime.runPromise(
        Effect.gen(function* () {
          const messageId = MessageIdSchema.make(yield* randomUuid);
          if (modelSelection) {
            // Keep thread metadata and the active provider session in sync. The
            // turn-level selection is what makes an existing session actually
            // switch models; metadata alone only updates the persisted label.
            yield* updateThreadMetadata({ threadId: thread.id, modelSelection });
          }
          yield* startThreadTurn(
            buildThreadReplyTurn({
              thread,
              messageId,
              text,
              attachments,
              ...(modelSelection ? { modelSelection } : {}),
              ...(context ? { context } : {}),
            }),
          );
        }),
      ),

    createThread: (input) =>
      runtime.runPromise(
        Effect.gen(function* () {
          const threadId = ThreadIdSchema.make(yield* randomUuid);
          const messageId = MessageIdSchema.make(yield* randomUuid);
          const createdAt = yield* DateTime.now.pipe(Effect.map(DateTime.formatIso));
          const worktreeToken = input.createWorktree ? yield* randomUuid : null;
          const worktreeBranch = worktreeToken
            ? buildTemporaryWorktreeBranchName((byteLength) =>
                worktreeToken.replaceAll("-", "").slice(0, byteLength * 2),
              )
            : null;
          yield* startThreadTurn({
            threadId,
            message: {
              messageId,
              role: "user",
              text: input.firstMessage,
              attachments: [...input.attachments],
            },
            modelSelection: input.modelSelection,
            titleSeed: TrimmedNonEmptyString.make(input.title),
            runtimeMode: input.runtimeMode,
            interactionMode: input.interactionMode,
            bootstrap: buildThreadCreationBootstrap(input, createdAt, worktreeBranch),
            createdAt,
          });
          return threadId;
        }),
      ),

    createProject: (workspaceRoot) =>
      runtime.runPromise(
        Effect.gen(function* () {
          const projectId = ProjectIdSchema.make(yield* randomUuid);
          yield* createProjectOp({
            projectId,
            title: TrimmedNonEmptyString.make(inferProjectTitleFromPath(workspaceRoot)),
            workspaceRoot: TrimmedNonEmptyString.make(workspaceRoot),
            createWorkspaceRootIfMissing: true,
            defaultModelSelection: null,
          });
          return projectId;
        }),
      ),

    implementPlan: (thread, planId) =>
      runtime.runPromise(
        Effect.gen(function* () {
          // Implementing means leaving plan mode so the agent executes the plan.
          // Persist the thread's interaction mode first (mirrors the web's
          // persistThreadSettingsForNextTurn → setThreadInteractionMode) so the
          // composer reflects build mode and later replies don't revert to plan.
          yield* setThreadInteractionMode({ threadId: thread.id, interactionMode: "default" });
          const messageId = MessageIdSchema.make(yield* randomUuid);
          yield* startThreadTurn({
            threadId: thread.id,
            message: {
              messageId,
              role: "user",
              text: "Implement the plan.",
              attachments: [],
            },
            runtimeMode: thread.runtimeMode,
            interactionMode: "default",
            sourceProposedPlan: {
              threadId: thread.id,
              planId: PlanId.make(planId),
            },
          });
        }),
      ),

    interrupt: (threadId) =>
      runtime.runPromise(interruptThreadTurn({ threadId }).pipe(Effect.asVoid)),

    approve: (threadId, requestId, decision) =>
      runtime.runPromise(
        respondToThreadApproval({
          threadId,
          requestId: RuntimeRequestId.make(requestId),
          decision,
        }).pipe(Effect.asVoid),
      ),

    respondUserInput: (threadId, requestId, answers) =>
      runtime.runPromise(
        respondToThreadUserInput({
          threadId,
          requestId: RuntimeRequestId.make(requestId),
          answers,
        }).pipe(Effect.asVoid),
      ),

    setRuntimeMode: (threadId, mode) =>
      runtime.runPromise(setThreadRuntimeMode({ threadId, runtimeMode: mode }).pipe(Effect.asVoid)),

    setInteractionMode: (threadId, mode) =>
      runtime.runPromise(
        setThreadInteractionMode({ threadId, interactionMode: mode }).pipe(Effect.asVoid),
      ),

    renameThread: (threadId, title) =>
      runtime.runPromise(
        updateThreadMetadata({ threadId, title: TrimmedNonEmptyString.make(title) }).pipe(
          Effect.asVoid,
        ),
      ),

    archiveThread: (threadId) =>
      runtime.runPromise(archiveThreadOp({ threadId }).pipe(Effect.asVoid)),

    unarchiveThread: (threadId) =>
      runtime.runPromise(unarchiveThreadOp({ threadId }).pipe(Effect.asVoid)),

    deleteThread: (threadId) =>
      runtime.runPromise(deleteThreadOp({ threadId }).pipe(Effect.asVoid)),

    settleThread: (threadId) =>
      runtime.runPromise(settleThreadOp({ threadId }).pipe(Effect.asVoid)),

    unsettleThread: (threadId) =>
      runtime.runPromise(unsettleThreadOp({ threadId, reason: "user" }).pipe(Effect.asVoid)),

    snoozeThread: (threadId, snoozedUntil) =>
      runtime.runPromise(snoozeThreadOp({ threadId, snoozedUntil }).pipe(Effect.asVoid)),

    unsnoozeThread: (threadId) =>
      runtime.runPromise(unsnoozeThreadOp({ threadId, reason: "user" }).pipe(Effect.asVoid)),

    stopSession: (threadId) =>
      runtime.runPromise(stopThreadSession({ threadId }).pipe(Effect.asVoid)),

    revertCheckpoint: (threadId, turnCount) =>
      runtime.runPromise(
        revertThreadCheckpoint({ threadId, turnCount: NonNegativeInt.make(turnCount) }).pipe(
          Effect.asVoid,
        ),
      ),

    subscribeTerminalMetadata: (onEvent) => {
      const stream = subscribe(WS_METHODS.subscribeTerminalMetadata, {}).pipe(
        Stream.tap((event) => Effect.sync(() => onEvent(event))),
      );
      return drainStreamUntilUnsubscribe(stream);
    },

    subscribeVcsStatus: (cwd, onStatus) => {
      // The stream delivers split local/remote results; fold them into the
      // combined VcsStatusResult the UI + gitActions logic expect. Remote may
      // be null (no upstream resolved yet) — fall back to "no remote" defaults.
      let local: VcsStatusLocalResult | null = null;
      let remote: VcsStatusRemoteResult | null = null;
      const emit = () => {
        const merged = mergeVcsStatus(local, remote);
        if (merged) onStatus(merged);
      };
      const stream = subscribe(WS_METHODS.subscribeVcsStatus, { cwd }).pipe(
        Stream.tap((event) =>
          Effect.sync(() => {
            if (event._tag === "snapshot") {
              local = event.local;
              remote = event.remote;
            } else if (event._tag === "localUpdated") {
              local = event.local;
            } else {
              remote = event.remote;
            }
            emit();
          }),
        ),
      );
      return drainStreamUntilUnsubscribe(stream);
    },

    runGitStackedAction: (input, onProgress) => {
      let finished: GitRunStackedActionResult | null = null;
      return runtime.runPromise(
        runStream(WS_METHODS.gitRunStackedAction, {
          actionId: `tui-action-${++gitActionSeq}`,
          cwd: input.cwd,
          action: input.action,
          ...(input.commitMessage ? { commitMessage: input.commitMessage } : {}),
          ...(input.featureBranch !== undefined ? { featureBranch: input.featureBranch } : {}),
        }).pipe(
          // The stream ends when the action completes; an action_failed event (or a
          // failed stream) surfaces as a rejected promise.
          Stream.runForEach((event) => {
            onProgress?.(event);
            if (event.kind === "action_failed") return Effect.fail(new Error(event.message));
            if (event.kind === "action_finished") finished = event.result;
            return Effect.void;
          }),
          Effect.map(() => finished),
        ),
      );
    },

    runGitPull: (cwd) =>
      runtime.runPromise(request(WS_METHODS.vcsPull, { cwd }).pipe(Effect.asVoid)),

    getTurnDiff: (threadId, toTurnCount) =>
      runtime.runPromise(
        request(ORCHESTRATION_V2_WS_METHODS.getTurnDiff, {
          threadId,
          fromTurnCount: NonNegativeInt.make(Math.max(0, toTurnCount - 1)),
          toTurnCount: NonNegativeInt.make(toTurnCount),
        }).pipe(Effect.map((result) => result.diff)),
      ),

    getFullThreadDiff: (threadId, toTurnCount) =>
      runtime.runPromise(
        request(ORCHESTRATION_V2_WS_METHODS.getFullThreadDiff, {
          threadId,
          toTurnCount: NonNegativeInt.make(toTurnCount),
        }).pipe(Effect.map((result) => result.diff)),
      ),

    listModels: () =>
      runtime.runPromise(
        request(WS_METHODS.serverGetConfig, {}).pipe(
          Effect.map((config) => flattenModelOptions(config.providers)),
        ),
      ),

    getServerConfig: () => runtime.runPromise(request(WS_METHODS.serverGetConfig, {})),

    listRefs: (cwd) =>
      runtime.runPromise(
        request(WS_METHODS.vcsListRefs, {
          cwd,
          limit: PositiveInt.make(100),
        }),
      ),

    switchRef: (cwd, refName) =>
      runtime.runPromise(
        request(WS_METHODS.vcsSwitchRef, {
          cwd: TrimmedNonEmptyString.make(cwd),
          refName: TrimmedNonEmptyString.make(refName),
        }),
      ),

    terminalOpen: (input) =>
      runtime.runPromise(
        request(WS_METHODS.terminalOpen, {
          threadId: input.threadId,
          terminalId: input.terminalId,
          cwd: input.cwd,
          worktreePath: input.worktreePath,
          cols: input.cols,
          rows: input.rows,
          ...(input.env ? { env: input.env } : {}),
        }).pipe(Effect.asVoid),
      ),

    terminalWrite: (threadId, terminalId, data) =>
      runtime.runPromise(
        request(WS_METHODS.terminalWrite, { threadId, terminalId, data }).pipe(Effect.asVoid),
      ),

    terminalResize: (threadId, terminalId, cols, rows) =>
      runtime.runPromise(
        request(WS_METHODS.terminalResize, { threadId, terminalId, cols, rows }).pipe(
          Effect.asVoid,
        ),
      ),

    terminalClear: (threadId, terminalId) =>
      runtime.runPromise(
        request(WS_METHODS.terminalClear, { threadId, terminalId }).pipe(Effect.asVoid),
      ),

    terminalRestart: (input) =>
      runtime.runPromise(request(WS_METHODS.terminalRestart, input).pipe(Effect.asVoid)),

    terminalClose: (threadId, terminalId) =>
      runtime.runPromise(
        request(WS_METHODS.terminalClose, { threadId, terminalId, deleteHistory: true }).pipe(
          Effect.asVoid,
        ),
      ),

    listTerminalIds: (threadId) =>
      runtime.runPromise(
        request(WS_METHODS.terminalList, { threadId }).pipe(
          Effect.map((result) => result.terminalIds),
        ),
      ),

    listEntries: (cwd) =>
      runtime
        .runPromise(
          request(WS_METHODS.projectsListEntries, { cwd }).pipe(Effect.map((r) => r.entries)),
        )
        .catch(() => []),

    readFile: (cwd, relativePath) =>
      runtime
        .runPromise(
          request(WS_METHODS.projectsReadFile, { cwd, relativePath }).pipe(
            Effect.map((r) => r.contents),
          ),
        )
        .catch(() => null),

    readFileBase64: (cwd, relativePath) =>
      runtime
        .runPromise(
          request(WS_METHODS.projectsReadFile, { cwd, relativePath, encoding: "base64" }).pipe(
            Effect.map(({ contents, byteLength, truncated }) => ({
              contents,
              byteLength,
              truncated,
            })),
          ),
        )
        .catch(() => null),

    getAttachmentUrl: (attachmentId) =>
      runtime
        .runPromise(
          request(WS_METHODS.assetsCreateUrl, {
            resource: { _tag: "attachment", attachmentId },
          }).pipe(
            Effect.map((result) => {
              try {
                return new URL(result.relativeUrl, origin || undefined).toString();
              } catch {
                return result.relativeUrl;
              }
            }),
          ),
        )
        .catch(() => null),

    getAttachmentImage: (attachmentId, resolvedUrl) =>
      attachmentImages.load(attachmentId, resolvedUrl),

    dispose: () => {
      disposeWarm();
      attachmentImages.clear();
      return runtime.dispose();
    },
  };
}

export type { OrchestrationShellSnapshot, OrchestrationThread };

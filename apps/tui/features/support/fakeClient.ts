import {
  type ClusterInvite,
  type ClusterMember,
  type ClusterStatus,
  DEFAULT_SERVER_SETTINGS,
  type GitRunStackedActionResult,
  type GitStackedAction,
  type OrchestrationThread,
  type ServerProvider,
  type TerminalAttachStreamEvent,
  type TerminalMetadataStreamEvent,
  type VcsStatusResult,
} from "@hal-c2/contracts";

import type {
  OrchestrationShellSnapshot,
  TuiClient,
  TuiConnectionPhase,
  TuiThreadPage,
} from "../../src/connection.ts";
import { flattenModelOptions } from "../../src/models.ts";
import { fakeFeatureClient, type FakeServer } from "./fakeFeatureClient.ts";

// Fixtures and an in-memory TuiClient, shared by the component tests and the
// Gherkin world. Feed it with `connect()` (the default shell snapshot),
// `emitShell(snapshot)` and `emitThread(detail)`.
//
// Every request method is recorded in `calls` (subscriptions and peeks are
// not), so steps assert on what the client was asked. `override(method, fn)`
// swaps one method's behaviour after boot. `workspaceFiles` backs
// `readFileBase64` unless a scenario passes its own.

export const project = {
  id: "p1",
  title: "Project one",
  workspaceRoot: "/workspace/project-one",
  defaultModelSelection: { instanceId: "codex", model: "gpt-5" },
  createdAt: "2026-07-13T00:00:00.000Z",
  updatedAt: "2026-07-13T00:00:00.000Z",
};

export const projectTwo = {
  ...project,
  id: "p2",
  title: "Project two",
  workspaceRoot: "/workspace/project-two",
  defaultModelSelection: { instanceId: "codex", model: "gpt-5-mini" },
};

const reasoning = (defaultId: string) => ({
  id: "reasoningEffort",
  label: "Reasoning",
  type: "select",
  options: ["low", "medium", "high"].map((id) => ({
    id,
    label: id[0]!.toUpperCase() + id.slice(1),
    ...(id === defaultId ? { isDefault: true } : {}),
  })),
});

/**
 * Codex (GPT-5 with effort and a fast-mode switch, GPT-5 Codex defaulting to
 * high effort) and Claude. Pass as `providers` to serve them from `listModels`.
 */
export const PROVIDERS = [
  {
    instanceId: "codex",
    driver: "codex",
    displayName: "Codex",
    enabled: true,
    models: [
      {
        slug: "gpt-5",
        name: "GPT-5",
        isCustom: false,
        capabilities: {
          optionDescriptors: [
            reasoning("medium"),
            { id: "fastMode", label: "Fast mode", type: "boolean" },
          ],
        },
      },
      {
        slug: "gpt-5-codex",
        name: "GPT-5 Codex",
        isCustom: false,
        capabilities: { optionDescriptors: [reasoning("high")] },
      },
    ],
  },
  {
    instanceId: "claude",
    driver: "claude",
    displayName: "Claude",
    enabled: true,
    models: [{ slug: "opus", name: "Opus", isCustom: false, capabilities: null }],
  },
] as unknown as ReadonlyArray<ServerProvider>;

export function thread(activities: OrchestrationThread["activities"] = []): OrchestrationThread {
  return {
    id: "t1",
    projectId: "p1",
    title: "Thread one",
    interactionMode: "default",
    runtimeMode: "full-access",
    branch: "main",
    worktreePath: null,
    updatedAt: "2026-07-13T00:00:00.000Z",
    session: { status: "idle" },
    latestTurn: null,
    messages: [],
    activities,
    checkpoints: [],
    modelSelection: { instanceId: "codex", model: "gpt-5" },
    proposedPlans: [],
    hasMoreActivities: false,
  } as unknown as OrchestrationThread;
}

export function shell(
  threads: OrchestrationShellSnapshot["threads"] = [
    {
      id: "t1",
      projectId: "p1",
      title: "Thread one",
      updatedAt: "2026-07-13T00:00:00.000Z",
      session: { status: "idle" },
      latestTurn: null,
    },
  ] as unknown as OrchestrationShellSnapshot["threads"],
  projects: OrchestrationShellSnapshot["projects"] = [
    project,
  ] as unknown as OrchestrationShellSnapshot["projects"],
): OrchestrationShellSnapshot {
  return {
    projects,
    threads,
  } as unknown as OrchestrationShellSnapshot;
}

/** One recorded client command: `{ method: "archiveThread", args: ["t1"] }`. */
export interface FakeClientCall {
  readonly method: string;
  readonly args: ReadonlyArray<unknown>;
}

// Streams and cache reads are plumbing, not commands a step asserts on.
const UNRECORDED = new Set([
  "subscribeConnection",
  "subscribeShell",
  "subscribeThread",
  "peekThread",
  "subscribeVcsStatus",
  "subscribeTerminalMetadata",
  "subscribeTerminal",
  "getServerConfig",
  "listModels",
  "listTerminalIds",
  "clusterStatus",
]);

export function fakeClient({
  detail: initialDetail,
  shellSnapshot = shell(),
  sendReply = () => Promise.resolve(),
  respondUserInput = () => Promise.resolve(),
  browseFilesystem = async (partialPath) => ({ parentPath: partialPath, entries: [] }) as never,
  discoverSourceControl = async () =>
    ({ versionControlSystems: [], sourceControlProviders: [] }) as never,
  lookupRepository = async (_provider, repository) =>
    ({
      provider: "github",
      nameWithOwner: repository,
      url: `https://github.com/${repository}`,
      sshUrl: `git@github.com:${repository}.git`,
    }) as never,
  cloneRepository = async (remoteUrl, destinationPath) =>
    ({ cwd: destinationPath, remoteUrl, repository: null }) as never,
  createProject = async () => "p-new" as never,
  createThread = async () => "t-new" as never,
  terminalClear = async () => {},
  terminalRestart = async () => {},
  terminalClose = async () => {},
  approve = async () => {},
  setInteractionMode,
  renameThread = async () => {},
  archiveThread = async () => {},
  unarchiveThread = async () => {},
  deleteThread = async () => {},
  settleThread = async () => {},
  unsettleThread = async () => {},
  stopSession = async () => {},
  vcsStatus,
  runGitPull,
  getAttachmentUrl = async () => null,
  getAttachmentImage = async () => null,
  readFileBase64,
  providers,
  listRefs = async () =>
    ({
      refs: [
        {
          name: "main",
          current: true,
          isDefault: true,
          worktreePath: null,
        },
      ],
      isRepo: true,
      hasPrimaryRemote: true,
      nextCursor: null,
      totalCount: 1,
    }) as never,
  switchRef = async (_cwd: string, refName: string) => ({ refName }) as never,
  getServerConfig = async () => ({ settings: DEFAULT_SERVER_SETTINGS }) as never,
  listModels = providers
    ? async () => flattenModelOptions(providers)
    : async () =>
        [
          {
            instanceId: "codex",
            model: "gpt-5",
            label: "GPT-5",
            providerLabel: "Codex",
            capabilities: null,
          },
        ] as never,
  listTerminalIds = async () => [],
  implementPlan = async () => {},
  revertCheckpoint = async () => {},
  getTurnDiff = async () => "",
  getFullThreadDiff = async () => "",
  listEntries = async () => [],
  readFile = async () => null,
  hostPlatform = "linux",
  terminalHistory = () => "",
  onTerminalWrite,
}: {
  readonly detail?: OrchestrationThread;
  readonly shellSnapshot?: OrchestrationShellSnapshot;
  readonly sendReply?: TuiClient["sendReply"];
  readonly respondUserInput?: TuiClient["respondUserInput"];
  readonly browseFilesystem?: TuiClient["browseFilesystem"];
  readonly discoverSourceControl?: TuiClient["discoverSourceControl"];
  readonly lookupRepository?: TuiClient["lookupRepository"];
  readonly cloneRepository?: TuiClient["cloneRepository"];
  readonly createProject?: TuiClient["createProject"];
  readonly createThread?: TuiClient["createThread"];
  readonly terminalClear?: TuiClient["terminalClear"];
  readonly terminalRestart?: TuiClient["terminalRestart"];
  readonly terminalClose?: TuiClient["terminalClose"];
  readonly approve?: TuiClient["approve"];
  readonly setInteractionMode?: TuiClient["setInteractionMode"];
  readonly renameThread?: TuiClient["renameThread"];
  readonly archiveThread?: TuiClient["archiveThread"];
  readonly unarchiveThread?: TuiClient["unarchiveThread"];
  readonly deleteThread?: TuiClient["deleteThread"];
  readonly settleThread?: TuiClient["settleThread"];
  readonly unsettleThread?: TuiClient["unsettleThread"];
  readonly stopSession?: TuiClient["stopSession"];
  readonly vcsStatus?: VcsStatusResult;
  /** Replaces the default pull (which ends as `setGitOutcome` says). */
  readonly runGitPull?: TuiClient["runGitPull"];
  readonly getAttachmentUrl?: TuiClient["getAttachmentUrl"];
  readonly getAttachmentImage?: TuiClient["getAttachmentImage"];
  readonly readFileBase64?: TuiClient["readFileBase64"];
  /** Providers whose usable models `listModels` reports (flattened like the server). */
  readonly providers?: ReadonlyArray<ServerProvider>;
  readonly listRefs?: TuiClient["listRefs"];
  readonly switchRef?: TuiClient["switchRef"];
  readonly getServerConfig?: TuiClient["getServerConfig"];
  readonly listModels?: TuiClient["listModels"];
  readonly listTerminalIds?: TuiClient["listTerminalIds"];
  readonly implementPlan?: TuiClient["implementPlan"];
  readonly revertCheckpoint?: TuiClient["revertCheckpoint"];
  readonly getTurnDiff?: TuiClient["getTurnDiff"];
  readonly getFullThreadDiff?: TuiClient["getFullThreadDiff"];
  readonly listEntries?: TuiClient["listEntries"];
  readonly readFile?: TuiClient["readFile"];
  readonly hostPlatform?: NodeJS.Platform;
  /** History replayed in the snapshot a terminal sends when it is attached. */
  readonly terminalHistory?: (threadId: string, terminalId: string) => string;
  /** Plays the program behind a terminal: sees each write after it is recorded. */
  readonly onTerminalWrite?: (terminal: FakeTerminal, data: string) => void;
} = {}): {
  readonly client: TuiClient;
  /** What the fake MC holds for the feature areas (fakeFeatureClient.ts). */
  readonly server: FakeServer;
  readonly connect: () => void;
  readonly emitShell: (snapshot: OrchestrationShellSnapshot) => void;
  /** The shell snapshot the client last delivered (or will deliver on connect). */
  readonly latestShell: () => OrchestrationShellSnapshot;
  readonly subscribedThreadIds: string[];
  /** Every command the client was asked to run, in order (subscriptions and reads excluded). */
  readonly calls: FakeClientCall[];
  readonly emitTerminalMetadata: (event: TerminalMetadataStreamEvent) => void;
  /** Push live detail to whoever subscribed to that thread. */
  readonly emitThread: (detail: OrchestrationThread, page?: TuiThreadPage) => void;
  /** Replace the git status; delivered now to subscribers and later to new ones (null: none). */
  readonly setVcsStatus: (status: VcsStatusResult | null) => void;
  /** The git mutations in `calls`, in order. */
  readonly gitCalls: ReadonlyArray<FakeGitCall>;
  /** How the next git mutations end (default: they succeed). */
  readonly setGitOutcome: (outcome: FakeGitOutcome) => void;
  /** The diff fetches in `calls`, in order. */
  readonly diffCalls: ReadonlyArray<FakeDiffCall>;
  /** Attached terminals by `threadId:terminalId`, with what they were sent. */
  readonly terminals: Map<string, FakeTerminal>;
  /** Replace one client method (still recorded). */
  readonly override: <K extends keyof TuiClient>(method: K, fn: TuiClient[K]) => void;
  /** Workspace files (relative path → bytes) served by the default `readFileBase64`. */
  readonly workspaceFiles: Map<string, Uint8Array>;
  /** The latest detail pushed or peeked for a thread. */
  readonly currentThread: (threadId: string) => OrchestrationThread | null;
  /** Move the connection to a phase (the client starts "connecting"). */
  readonly emitConnection: (phase: TuiConnectionPhase) => void;
  /** The MC's cluster: its members, the invite it hands out, why it refuses a join. */
  readonly cluster: FakeCluster;
} {
  const cluster: FakeCluster = {
    members: [],
    invite: {
      link: "http://192.168.1.20:3773/pair#token=cluster-invite",
      expiresAt: "2026-09-28T12:05:00Z",
      localOnly: false,
    },
    joinRefusal: null,
  };
  const clusterStatus = (): ClusterStatus => ({
    clustered: true,
    id: "env-local",
    label: "This machine",
    mc: "hal-c2-env-local",
    addresses: ["192.168.1.20:47730"],
    members: cluster.members,
  });
  let connectionPhase: TuiConnectionPhase = "connecting";
  let latestShell = shellSnapshot;
  const connectionSubscribers = new Set<(phase: TuiConnectionPhase) => void>();
  const terminals = new Map<string, FakeTerminal>();
  const terminalFor = (threadId: string, terminalId: string): FakeTerminal => {
    const key = `${threadId}:${terminalId}`;
    let terminal = terminals.get(key);
    if (!terminal) {
      terminal = {
        threadId,
        terminalId,
        attach: null,
        attachCount: 0,
        writes: [],
        listener: null,
        emit: (event) => terminal!.listener?.(event),
      };
      terminals.set(key, terminal);
    }
    return terminal;
  };
  let shellSubscriber: ((snapshot: OrchestrationShellSnapshot) => void) | null = null;
  let terminalMetadataSubscriber: ((event: TerminalMetadataStreamEvent) => void) | null = null;
  const subscribedThreadIds: string[] = [];
  const threadSubscribers = new Map<
    string,
    (thread: OrchestrationThread, page: TuiThreadPage) => void
  >();
  const details = new Map<string, OrchestrationThread>();
  if (initialDetail) details.set(initialDetail.id, initialDetail);
  const workspaceFiles = new Map<string, Uint8Array>();
  const currentThread = (threadId: string) => details.get(threadId) ?? null;
  const emitThread = (
    next: OrchestrationThread,
    page: TuiThreadPage = { hasMore: false, loadingOlder: false },
  ) => {
    details.set(next.id, next);
    threadSubscribers.get(next.id)?.(next, page);
  };
  // The server echoes a thread setting back through the live detail.
  const echo =
    (patch: (mode: never) => Partial<OrchestrationThread>) =>
    async (threadId: string, mode: never) => {
      const current = details.get(threadId);
      if (current) emitThread({ ...current, ...patch(mode) });
    };
  let currentVcsStatus: VcsStatusResult | null = vcsStatus ?? null;
  const vcsSubscribers = new Set<(status: VcsStatusResult) => void>();
  let gitOutcome: FakeGitOutcome = { kind: "succeed" };
  const settleGit = <T>(value: T): Promise<T> => {
    const outcome = gitOutcome;
    if (outcome.kind === "hang") return new Promise<T>(() => {});
    if (outcome.kind === "fail") return Promise.reject(new Error(outcome.message));
    return Promise.resolve(value);
  };
  const feature = fakeFeatureClient();
  const client = {
    ...feature.client,
    hostPlatform,
    subscribeConnection: (onPhase: (phase: TuiConnectionPhase) => void) => {
      connectionSubscribers.add(onPhase);
      onPhase(connectionPhase);
      return () => {
        connectionSubscribers.delete(onPhase);
      };
    },
    browseFilesystem,
    discoverSourceControl,
    clusterStatus: async () => clusterStatus(),
    clusterInvite: async () => cluster.invite,
    // Joining adds the machine the link points at.
    clusterJoin: async (link: string) => {
      if (cluster.joinRefusal) throw new Error(cluster.joinRefusal);
      const label = new URL(link).hostname;
      cluster.members = [
        ...cluster.members,
        { id: `env-${label}`, label, addresses: [`${label}:47730`], connected: true },
      ];
      return clusterStatus();
    },
    clusterRemove: async (id: string) => {
      cluster.members = cluster.members.filter((member) => member.id !== id);
      return clusterStatus();
    },
    lookupRepository,
    cloneRepository,
    subscribeShell: (onSnapshot: (snapshot: OrchestrationShellSnapshot) => void) => {
      shellSubscriber = onSnapshot;
      // Connected before anyone listened: the subscriber gets the snapshot right away.
      if (connectionPhase === "connected") onSnapshot(latestShell);
      return () => {
        shellSubscriber = null;
      };
    },
    subscribeThread: (
      threadId: string,
      onThread: (thread: OrchestrationThread, page: TuiThreadPage) => void,
    ) => {
      subscribedThreadIds.push(threadId);
      threadSubscribers.set(threadId, onThread);
      return () => {
        if (threadSubscribers.get(threadId) === onThread) threadSubscribers.delete(threadId);
      };
    },
    peekThread: (threadId: string) => details.get(threadId) ?? null,
    subscribeVcsStatus: (_cwd: string, onStatus: (status: VcsStatusResult) => void) => {
      vcsSubscribers.add(onStatus);
      if (currentVcsStatus) onStatus(currentVcsStatus);
      return () => {
        vcsSubscribers.delete(onStatus);
      };
    },
    subscribeTerminalMetadata: (onEvent: (event: TerminalMetadataStreamEvent) => void) => {
      terminalMetadataSubscriber = onEvent;
      return () => {
        terminalMetadataSubscriber = null;
      };
    },
    sendReply,
    respondUserInput,
    implementPlan,
    revertCheckpoint,
    loadOlderThreadTurns: () => true,
    getTurnDiff,
    getFullThreadDiff,
    createProject,
    createThread,
    listEntries,
    readFile,
    subscribeTerminal: (
      input: Parameters<TuiClient["subscribeTerminal"]>[0],
      onEvent: (event: TerminalAttachStreamEvent) => void,
    ) => {
      const terminal = terminalFor(input.threadId, input.terminalId);
      terminal.attach = input;
      terminal.attachCount += 1;
      terminal.listener = onEvent;
      // The server answers an attach with the session's snapshot.
      onEvent({
        type: "snapshot",
        threadId: input.threadId,
        terminalId: input.terminalId,
        createdAt: "2026-07-13T00:00:00.000Z",
        snapshot: {
          threadId: input.threadId,
          terminalId: input.terminalId,
          cwd: input.cwd,
          worktreePath: input.worktreePath,
          status: "running",
          pid: 1,
          history: terminalHistory(input.threadId, input.terminalId),
          exitCode: null,
          exitSignal: null,
          updatedAt: "2026-07-13T00:00:00.000Z",
        },
      } as unknown as TerminalAttachStreamEvent);
      return () => {
        if (terminal.listener === onEvent) terminal.listener = null;
      };
    },
    terminalWrite: async (threadId: string, terminalId: string, data: string) => {
      const terminal = terminalFor(threadId, terminalId);
      terminal.writes.push(data);
      onTerminalWrite?.(terminal, data);
    },
    terminalResize: async () => {},
    terminalClear,
    terminalRestart,
    setInteractionMode:
      setInteractionMode ?? echo((interactionMode) => ({ interactionMode }) as never),
    setRuntimeMode: echo((runtimeMode) => ({ runtimeMode }) as never),
    interrupt: async () => {},
    renameThread,
    archiveThread,
    unarchiveThread,
    deleteThread,
    settleThread,
    unsettleThread,
    stopSession,
    terminalClose,
    approve,
    listTerminalIds,
    listModels,
    getServerConfig,
    listRefs,
    switchRef,
    getAttachmentUrl,
    getAttachmentImage,
    readFileBase64:
      readFileBase64 ??
      (async (_cwd: string, relativePath: string) => {
        const bytes = workspaceFiles.get(relativePath);
        if (!bytes) return null;
        return {
          contents: Buffer.from(bytes).toString("base64"),
          byteLength: bytes.byteLength,
          truncated: false,
        };
      }),
    runGitStackedAction: () =>
      settleGit(gitOutcome.kind === "succeed" ? (gitOutcome.result ?? null) : null),
    runGitPull: (cwd: string) => (runGitPull ? runGitPull(cwd) : settleGit(undefined)),
  } as unknown as TuiClient;
  const calls: FakeClientCall[] = [];
  // `impls` holds the behaviour (override swaps it); `recorded` is what the host calls.
  const impls = client as unknown as Record<string, unknown>;
  const recorded = { ...impls } as Record<string, unknown>;
  for (const [method, impl] of Object.entries(impls)) {
    if (typeof impl !== "function") continue;
    const unrecorded = UNRECORDED.has(method);
    recorded[method] = (...args: unknown[]) => {
      if (!unrecorded) calls.push({ method, args });
      return (impls[method] as (...values: unknown[]) => unknown)(...args);
    };
  }
  return {
    client: recorded as unknown as TuiClient,
    server: feature.server,
    calls,
    connect: () => {
      connectionPhase = "connected";
      latestShell = shellSnapshot;
      for (const onPhase of connectionSubscribers) onPhase(connectionPhase);
      shellSubscriber?.(shellSnapshot);
    },
    latestShell: () => latestShell,
    emitShell: (snapshot) => {
      latestShell = snapshot;
      shellSubscriber?.(snapshot);
    },
    subscribedThreadIds,
    emitTerminalMetadata: (event) => terminalMetadataSubscriber?.(event),
    terminals,
    emitThread,
    setVcsStatus: (status) => {
      currentVcsStatus = status;
      if (status) for (const subscriber of vcsSubscribers) subscriber(status);
    },
    get gitCalls() {
      return calls.flatMap((call): FakeGitCall[] => {
        if (call.method === "runGitStackedAction") {
          const input = call.args[0] as Parameters<TuiClient["runGitStackedAction"]>[0];
          return [{ method: "runGitStackedAction", ...input }];
        }
        if (call.method === "runGitPull") {
          return [{ method: "runGitPull", cwd: call.args[0] as string }];
        }
        return [];
      });
    },
    setGitOutcome: (outcome) => {
      gitOutcome = outcome;
    },
    get diffCalls() {
      return calls.flatMap((call): FakeDiffCall[] =>
        call.method === "getTurnDiff" || call.method === "getFullThreadDiff"
          ? [
              {
                method: call.method,
                threadId: call.args[0] as string,
                toTurnCount: call.args[1] as number,
              },
            ]
          : [],
      );
    },
    override: (method, fn) => {
      impls[method] = fn;
    },
    workspaceFiles,
    currentThread,
    cluster,
    emitConnection: (phase) => {
      connectionPhase = phase;
      for (const onPhase of connectionSubscribers) onPhase(phase);
    },
  };
}

export interface FakeCluster {
  members: ClusterMember[];
  invite: ClusterInvite;
  /** The MC's reason for refusing a join; null joins. */
  joinRefusal: string | null;
}

export type FakeGitCall =
  | {
      readonly method: "runGitStackedAction";
      readonly cwd: string;
      readonly action: GitStackedAction;
      readonly commitMessage?: string;
      readonly featureBranch?: boolean;
    }
  | { readonly method: "runGitPull"; readonly cwd: string };

export type FakeGitOutcome =
  | { readonly kind: "succeed"; readonly result?: GitRunStackedActionResult }
  | { readonly kind: "fail"; readonly message: string }
  /** Never settles: the action stays running. */
  | { readonly kind: "hang" };

export interface FakeDiffCall {
  readonly method: "getTurnDiff" | "getFullThreadDiff";
  readonly threadId: string;
  readonly toTurnCount: number;
}

/** One attached terminal session in the fake: what it was attached with and sent. */
export interface FakeTerminal {
  readonly threadId: string;
  readonly terminalId: string;
  attach: Parameters<TuiClient["subscribeTerminal"]>[0] | null;
  attachCount: number;
  /** Bytes written to the PTY (keys and pastes). */
  readonly writes: string[];
  listener: ((event: TerminalAttachStreamEvent) => void) | null;
  /** Push a stream event to the attached client, if any. */
  readonly emit: (event: TerminalAttachStreamEvent) => void;
}

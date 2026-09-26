import {
  DEFAULT_SERVER_SETTINGS,
  type GitRunStackedActionResult,
  type GitStackedAction,
  type OrchestrationThread,
  type TerminalAttachStreamEvent,
  type TerminalMetadataStreamEvent,
  type VcsStatusResult,
} from "@t3tools/contracts";

import type { OrchestrationShellSnapshot, TuiClient, TuiThreadPage } from "../../src/connection.ts";

// Fixtures and an in-memory TuiClient, shared by the component tests and the
// Gherkin world. Feed it with `connect()` (the default shell snapshot),
// `emitShell(snapshot)` and `emitThread(detail)`.

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
  "subscribeShell",
  "subscribeThread",
  "peekThread",
  "subscribeVcsStatus",
  "subscribeTerminalMetadata",
  "subscribeTerminal",
  "getServerConfig",
  "listModels",
  "listTerminalIds",
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
  setInteractionMode = async () => {},
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
  readFileBase64 = async () => null,
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
  listModels = async () =>
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
  readonly connect: () => void;
  readonly emitShell: (snapshot: OrchestrationShellSnapshot) => void;
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
} {
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
  // The warm cache: the detail given, then whatever was last emitted.
  let detail = initialDetail;
  let currentVcsStatus: VcsStatusResult | null = vcsStatus ?? null;
  const vcsSubscribers = new Set<(status: VcsStatusResult) => void>();
  let gitOutcome: FakeGitOutcome = { kind: "succeed" };
  const settleGit = <T>(value: T): Promise<T> => {
    const outcome = gitOutcome;
    if (outcome.kind === "hang") return new Promise<T>(() => {});
    if (outcome.kind === "fail") return Promise.reject(new Error(outcome.message));
    return Promise.resolve(value);
  };
  const client = {
    hostPlatform,
    browseFilesystem,
    discoverSourceControl,
    lookupRepository,
    cloneRepository,
    subscribeShell: (onSnapshot: (snapshot: OrchestrationShellSnapshot) => void) => {
      shellSubscriber = onSnapshot;
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
    peekThread: () => detail ?? null,
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
    setInteractionMode,
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
    readFileBase64,
    runGitStackedAction: () =>
      settleGit(gitOutcome.kind === "succeed" ? (gitOutcome.result ?? null) : null),
    runGitPull: (cwd: string) => (runGitPull ? runGitPull(cwd) : settleGit(undefined)),
  } as unknown as TuiClient;
  const calls: FakeClientCall[] = [];
  const record = client as unknown as Record<string, unknown>;
  for (const [method, value] of Object.entries(record)) {
    if (typeof value !== "function" || UNRECORDED.has(method)) continue;
    record[method] = (...args: unknown[]) => {
      calls.push({ method, args });
      return (value as (...args: unknown[]) => unknown)(...args);
    };
  }
  return {
    client,
    calls,
    connect: () => shellSubscriber?.(shellSnapshot),
    emitShell: (snapshot) => shellSubscriber?.(snapshot),
    subscribedThreadIds,
    emitTerminalMetadata: (event) => terminalMetadataSubscriber?.(event),
    terminals,
    emitThread: (next, page = { hasMore: false, loadingOlder: false }) => {
      detail = next;
      threadSubscribers.get(next.id)?.(next, page);
    },
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
  };
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

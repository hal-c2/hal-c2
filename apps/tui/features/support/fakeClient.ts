import {
  DEFAULT_SERVER_SETTINGS,
  type OrchestrationThread,
  type TerminalMetadataStreamEvent,
  type VcsStatusResult,
} from "@t3tools/contracts";

import type {
  OrchestrationShellSnapshot,
  TuiClient,
  TuiConnectionPhase,
  TuiThreadPage,
} from "../../src/connection.ts";

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

export function fakeClient({
  detail,
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
  vcsStatus,
  runGitPull = async () => {},
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
  readonly vcsStatus?: VcsStatusResult;
  readonly runGitPull?: TuiClient["runGitPull"];
  readonly getAttachmentUrl?: TuiClient["getAttachmentUrl"];
  readonly getAttachmentImage?: TuiClient["getAttachmentImage"];
  readonly readFileBase64?: TuiClient["readFileBase64"];
  readonly listRefs?: TuiClient["listRefs"];
  readonly switchRef?: TuiClient["switchRef"];
  readonly getServerConfig?: TuiClient["getServerConfig"];
  readonly listModels?: TuiClient["listModels"];
  readonly listTerminalIds?: TuiClient["listTerminalIds"];
} = {}): {
  readonly client: TuiClient;
  readonly connect: () => void;
  readonly emitShell: (snapshot: OrchestrationShellSnapshot) => void;
  readonly subscribedThreadIds: string[];
  readonly emitTerminalMetadata: (event: TerminalMetadataStreamEvent) => void;
  /** Push live detail to whoever subscribed to that thread. */
  readonly emitThread: (detail: OrchestrationThread, page?: TuiThreadPage) => void;
  /** Move the connection to a phase (the client starts "connecting"). */
  readonly emitConnection: (phase: TuiConnectionPhase) => void;
} {
  let connectionPhase: TuiConnectionPhase = "connecting";
  let latestShell = shellSnapshot;
  const connectionSubscribers = new Set<(phase: TuiConnectionPhase) => void>();
  let shellSubscriber: ((snapshot: OrchestrationShellSnapshot) => void) | null = null;
  let terminalMetadataSubscriber: ((event: TerminalMetadataStreamEvent) => void) | null = null;
  const subscribedThreadIds: string[] = [];
  const threadSubscribers = new Map<
    string,
    (thread: OrchestrationThread, page: TuiThreadPage) => void
  >();
  const client = {
    hostPlatform: "linux",
    subscribeConnection: (onPhase: (phase: TuiConnectionPhase) => void) => {
      connectionSubscribers.add(onPhase);
      onPhase(connectionPhase);
      return () => {
        connectionSubscribers.delete(onPhase);
      };
    },
    browseFilesystem,
    discoverSourceControl,
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
    peekThread: () => detail ?? null,
    subscribeVcsStatus: (_cwd: string, onStatus: (status: VcsStatusResult) => void) => {
      if (vcsStatus) onStatus(vcsStatus);
      return () => {};
    },
    subscribeTerminalMetadata: (onEvent: (event: TerminalMetadataStreamEvent) => void) => {
      terminalMetadataSubscriber = onEvent;
      return () => {
        terminalMetadataSubscriber = null;
      };
    },
    sendReply,
    respondUserInput,
    createProject,
    createThread,
    subscribeTerminal: () => () => {},
    terminalWrite: async () => {},
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
    runGitStackedAction: async () => {},
    runGitPull,
  } as unknown as TuiClient;
  return {
    client,
    connect: () => {
      connectionPhase = "connected";
      latestShell = shellSnapshot;
      for (const onPhase of connectionSubscribers) onPhase(connectionPhase);
      shellSubscriber?.(shellSnapshot);
    },
    emitShell: (snapshot) => {
      latestShell = snapshot;
      shellSubscriber?.(snapshot);
    },
    subscribedThreadIds,
    emitTerminalMetadata: (event) => terminalMetadataSubscriber?.(event),
    emitThread: (next, page = { hasMore: false, loadingOlder: false }) =>
      threadSubscribers.get(next.id)?.(next, page),
    emitConnection: (phase) => {
      connectionPhase = phase;
      for (const onPhase of connectionSubscribers) onPhase(phase);
    },
  };
}

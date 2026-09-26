import {
  DEFAULT_SERVER_SETTINGS,
  type OrchestrationThread,
  type ServerProvider,
  type TerminalMetadataStreamEvent,
  type VcsStatusResult,
} from "@t3tools/contracts";

import type { OrchestrationShellSnapshot, TuiClient, TuiThreadPage } from "../../src/connection.ts";
import { flattenModelOptions } from "../../src/models.ts";

// Fixtures and an in-memory TuiClient, shared by the component tests and the
// Gherkin world. Feed it with `connect()` (the default shell snapshot),
// `emitShell(snapshot)` and `emitThread(detail)`.
//
// Every request method is recorded in `calls` (subscriptions and peeks are
// not), so steps assert on what the client was asked. `override(method, fn)`
// swaps one method's behaviour after boot. `workspaceFiles` backs
// `readFileBase64` unless a scenario passes its own.

export interface FakeCall {
  readonly method: string;
  readonly args: ReadonlyArray<unknown>;
}

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
  setInteractionMode,
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
  /** Providers whose usable models `listModels` reports (flattened like the server). */
  readonly providers?: ReadonlyArray<ServerProvider>;
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
  /** Requests made so far, oldest first. */
  readonly calls: FakeCall[];
  /** Replace one client method (still recorded). */
  readonly override: <K extends keyof TuiClient>(method: K, fn: TuiClient[K]) => void;
  /** Workspace files (relative path → bytes) served by the default `readFileBase64`. */
  readonly workspaceFiles: Map<string, Uint8Array>;
  /** The latest detail pushed or peeked for a thread. */
  readonly currentThread: (threadId: string) => OrchestrationThread | null;
} {
  let shellSubscriber: ((snapshot: OrchestrationShellSnapshot) => void) | null = null;
  let terminalMetadataSubscriber: ((event: TerminalMetadataStreamEvent) => void) | null = null;
  const subscribedThreadIds: string[] = [];
  const threadSubscribers = new Map<
    string,
    (thread: OrchestrationThread, page: TuiThreadPage) => void
  >();
  const details = new Map<string, OrchestrationThread>();
  if (detail) details.set(detail.id, detail);
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
  const client = {
    hostPlatform: "linux",
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
    peekThread: (threadId: string) => details.get(threadId) ?? detail ?? null,
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
    setInteractionMode:
      setInteractionMode ?? echo((interactionMode) => ({ interactionMode }) as never),
    setRuntimeMode: echo((runtimeMode) => ({ runtimeMode }) as never),
    interrupt: async () => {},
    implementPlan: async () => {},
    stopSession: async () => {},
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
    runGitStackedAction: async () => {},
    runGitPull,
  } as unknown as TuiClient;
  const calls: FakeCall[] = [];
  const impls = client as unknown as Record<string, unknown>;
  const recorded = { ...impls } as Record<string, unknown>;
  for (const [method, impl] of Object.entries(impls)) {
    if (typeof impl !== "function" || /^(subscribe|peek)/.test(method)) continue;
    recorded[method] = (...args: unknown[]) => {
      calls.push({ method, args });
      return (impls[method] as (...values: unknown[]) => unknown)(...args);
    };
  }
  return {
    client: recorded as unknown as TuiClient,
    connect: () => shellSubscriber?.(shellSnapshot),
    emitShell: (snapshot) => shellSubscriber?.(snapshot),
    subscribedThreadIds,
    emitTerminalMetadata: (event) => terminalMetadataSubscriber?.(event),
    emitThread,
    calls,
    override: (method, fn) => {
      impls[method] = fn;
    },
    workspaceFiles,
    currentThread,
  };
}

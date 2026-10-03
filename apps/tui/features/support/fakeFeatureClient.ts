// The fake's side of src/featureClient.ts: an in-memory answer for each
// request the feature areas make. Scenarios shape it through `ctx.fake.server`
// (or swap one method with `ctx.fake.override`).
import {
  DEFAULT_SERVER_SETTINGS,
  type GitActionProgressEvent,
  type GitStackedAction,
  type PreviewSessionSnapshot,
  type ProviderInstanceMutation,
  type RelayClientStatus,
  type ServerProvider,
  type ServerSettings,
  type VcsStatusResult,
} from "@hal-c2/contracts";

import type { OrchestrationShellSnapshot } from "../../src/connection.ts";
import type { TuiFeatureClient } from "../../src/featureClient.ts";

/** What the fake MC holds for the feature areas. */
export interface FakeServer {
  /** Files written through `writeFile`, by `cwd:relativePath`. */
  readonly written: Map<string, string>;
  /** Every configured provider, as `refreshProviders` and the config report them. */
  providers: ServerProvider[];
  /** What a refresh finds: replaces `providers` when the next refresh runs. */
  afterRefresh: ServerProvider[] | null;
  /** How an update ends: the providers it leaves, or the reason it fails. */
  update: { providers: ServerProvider[] } | { error: string } | null;
  settings: ServerSettings;
  /** The instance mutations `updateSettings` carried, in order. */
  readonly instanceMutations: ProviderInstanceMutation[];
  /** The open previews of every thread. */
  previews: PreviewSessionSnapshot[];
  /** The repository's worktrees besides the main checkout. */
  worktrees: Array<{ path: string; refName: string }>;
  /** The relay client on the server (missing until installed). */
  relay: RelayClientStatus;
  /** The diff against a base, by `<baseRef>:all` or `<baseRef>:no-whitespace`. */
  readonly reviewDiffs: Map<string, string>;
  /** Pull requests on the provider, found by number from any reference. */
  pullRequests: Array<{
    number: number;
    title: string;
    url: string;
    baseBranch: string;
    headBranch: string;
    state: "open" | "closed" | "merged";
  }>;
}

/** The fake's shell, which project changes rewrite and push like the MC does. */
export interface FakeShellPort {
  readonly get: () => OrchestrationShellSnapshot;
  readonly push: (snapshot: OrchestrationShellSnapshot) => void;
  /** The checkout's status, as the status stream last delivered it. */
  readonly vcs: () => VcsStatusResult | null;
  readonly setVcs: (status: VcsStatusResult) => void;
}

const PHASES: Record<GitStackedAction, ReadonlyArray<"commit" | "push" | "pr">> = {
  commit: ["commit"],
  push: ["push"],
  create_pr: ["push", "pr"],
  commit_push: ["commit", "push"],
  commit_push_pr: ["commit", "push", "pr"],
};
const PHASE_LABELS = { commit: "Committing", push: "Pushing", pr: "Creating pull request" };
const HOOKS = {
  commit: { name: "pre-commit", output: "lint-staged: 2 files checked" },
  push: { name: "pre-push", output: "tests: 42 passed" },
} as const;

/** What the MC streams while a stacked action runs: each phase, and the hooks git fires in it. */
export function fakeGitProgress(input: {
  readonly cwd: string;
  readonly action: GitStackedAction;
}): GitActionProgressEvent[] {
  const base = { actionId: "fake-action", cwd: input.cwd, action: input.action };
  const phases = PHASES[input.action];
  const events: unknown[] = [{ ...base, kind: "action_started", phases }];
  for (const phase of phases) {
    events.push({ ...base, kind: "phase_started", phase, label: PHASE_LABELS[phase] });
    if (phase === "pr") continue;
    const hook = HOOKS[phase];
    events.push(
      { ...base, kind: "hook_started", hookName: hook.name },
      { ...base, kind: "hook_output", hookName: hook.name, stream: "stdout", text: hook.output },
      { ...base, kind: "hook_finished", hookName: hook.name, exitCode: 0, durationMs: 12 },
    );
  }
  return events as GitActionProgressEvent[];
}

/** `#42`, `gh pr checkout 42` and `https://…/pull/42` all name pull request 42. */
const pullRequestNumber = (reference: string): number | null => {
  const match = /(?:\/pull\/|#|checkout\s+)(\d+)\s*$/.exec(reference.trim());
  return match ? Number(match[1]) : null;
};

export function fakeFeatureClient(shell: FakeShellPort): {
  client: TuiFeatureClient;
  server: FakeServer;
} {
  const server: FakeServer = {
    written: new Map(),
    providers: [],
    afterRefresh: null,
    update: null,
    settings: DEFAULT_SERVER_SETTINGS,
    instanceMutations: [],
    previews: [],
    worktrees: [],
    pullRequests: [],
    reviewDiffs: new Map(),
    relay: { status: "missing", version: "2026.6.0" },
  };
  let previewCount = 0;
  const status = () => {
    const current = shell.vcs();
    if (!current) throw new Error("not a repository");
    return current;
  };
  const pullRequest = (reference: string) => {
    const found = server.pullRequests.find(
      (candidate) => candidate.number === pullRequestNumber(reference),
    );
    if (!found) throw new Error(`no pull request for "${reference}"`);
    return found;
  };
  const client: TuiFeatureClient = {
    refreshVcsStatus: async () => status(),
    relayStatus: async () => server.relay,
    // The server downloads, checks and activates the binary, saying which stage it is in.
    installRelay: async (onStage) => {
      for (const stage of ["downloading", "verifying", "installing", "activating"] as const) {
        onStage(stage);
      }
      server.relay = {
        status: "available",
        executablePath: "/opt/hal-c2/relay/cloudflared",
        source: "managed",
        version: server.relay.version,
      };
      return server.relay;
    },
    reviewDiff: async (_cwd, baseRef, ignoreWhitespace) =>
      server.reviewDiffs.get(`${baseRef}:${ignoreWhitespace ? "no-whitespace" : "all"}`) ?? "",
    createRef: async (_cwd, refName) => {
      shell.setVcs({ ...status(), refName, isDefaultRef: false, hasUpstream: false } as never);
      return refName;
    },
    createWorktree: async (cwd, _baseRef, newRef) => {
      const worktree = { path: `${cwd}-worktrees/${newRef.replaceAll("/", "-")}`, refName: newRef };
      server.worktrees = [...server.worktrees, worktree];
      return worktree as never;
    },
    removeWorktree: async (_cwd, path) => {
      server.worktrees = server.worktrees.filter((worktree) => worktree.path !== path);
    },
    initRepository: async () => {
      shell.setVcs({
        isRepo: true,
        hasPrimaryRemote: false,
        isDefaultRef: true,
        refName: "main",
        hasWorkingTreeChanges: false,
        workingTree: { files: [], insertions: 0, deletions: 0 },
        hasUpstream: false,
        aheadCount: 0,
        behindCount: 0,
        pr: null,
      } as never);
    },
    resolvePullRequest: async (_cwd, reference) => pullRequest(reference) as never,
    preparePullRequest: async (input) => {
      const found = pullRequest(input.reference);
      return {
        pullRequest: found,
        branch: found.headBranch,
        worktreePath:
          input.mode === "worktree" ? `${input.cwd}-worktrees/pr-${found.number}` : null,
        isOnPullRequestHead: true,
      } as never;
    },
    publishRepository: async (input) => {
      const remoteUrl = `git@github.com:${input.repository}.git`;
      shell.setVcs({ ...status(), hasPrimaryRemote: true, hasUpstream: true } as never);
      return {
        repository: {
          provider: input.provider,
          nameWithOwner: input.repository,
          url: `https://github.com/${input.repository}`,
          sshUrl: remoteUrl,
        },
        remoteName: "origin",
        remoteUrl,
        branch: status().refName ?? "main",
        status: "pushed",
      } as never;
    },
    writeFile: async (cwd, relativePath, contents) => {
      server.written.set(`${cwd}:${relativePath}`, contents);
    },
    refreshProviders: async () => {
      if (server.afterRefresh) server.providers = server.afterRefresh;
      server.afterRefresh = null;
      return server.providers;
    },
    updateProvider: async () => {
      if (!server.update) throw new Error("nothing to update");
      if ("error" in server.update) throw new Error(server.update.error);
      server.providers = server.update.providers;
      return server.providers;
    },
    updateSettings: async (patch, mutation) => {
      let providerInstances = server.settings.providerInstances;
      if (mutation) {
        server.instanceMutations.push(mutation);
        const { [mutation.instanceId]: _removed, ...rest } = providerInstances;
        providerInstances =
          mutation.operation === "remove"
            ? (rest as typeof providerInstances)
            : { ...providerInstances, [mutation.instanceId]: mutation.instance };
      }
      server.settings = { ...server.settings, ...patch, providerInstances } as ServerSettings;
      return server.settings;
    },
    updateProject: async (projectId, change) => {
      const current = shell.get();
      shell.push({
        ...current,
        projects: current.projects.map((project) =>
          project.id === projectId ? { ...project, ...change } : project,
        ),
      } as OrchestrationShellSnapshot);
    },
    // The MC drops the project and its threads from the shell; nothing on disk changes.
    deleteProject: async (projectId) => {
      const current = shell.get();
      shell.push({
        ...current,
        projects: current.projects.filter((project) => project.id !== projectId),
        threads: current.threads.filter((thread) => thread.projectId !== projectId),
      } as OrchestrationShellSnapshot);
    },
    listPreviews: async (threadId) =>
      server.previews.filter((preview) => preview.threadId === threadId),
    openPreview: async (threadId, url) => {
      previewCount += 1;
      const preview = {
        threadId,
        tabId: `tab-${previewCount}`,
        navStatus: { _tag: "Success", url, title: url },
        canGoBack: false,
        canGoForward: false,
        updatedAt: "2026-07-15T12:00:00.000Z",
      } as unknown as PreviewSessionSnapshot;
      server.previews = [...server.previews, preview];
      return preview;
    },
    refreshPreview: async () => {},
    closePreview: async (threadId, tabId) => {
      server.previews = server.previews.filter(
        (preview) => !(preview.threadId === threadId && preview.tabId === tabId),
      );
    },
  };
  return { client, server };
}

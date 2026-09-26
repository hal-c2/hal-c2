// A small in-memory environment behind the fake client: projects, threads and
// the server's answers to thread commands. Givens shape it before the client
// connects; after that every change is pushed as a fresh shell snapshot, as
// the real server does. Steps read `ctx.fake.calls` for what the client asked.
import { DEFAULT_SERVER_SETTINGS, type ThreadEnvMode, type VcsRef } from "@hal-c2/contracts";

import type { OrchestrationShellSnapshot } from "../../src/connection.ts";
import { boot, useClient, type World } from "./world.ts";

// Scenarios run on a pinned clock: noon, mid-July 2026.
export const DEFAULT_NOW_MS = Date.parse("2026-07-15T12:00:00.000Z");
const CREATED_BASE_MS = Date.parse("2026-07-15T08:00:00.000Z");
const MINUTE_MS = 60_000;

export interface EnvProject {
  id: string;
  title: string;
  workspaceRoot: string;
  defaultModelSelection: { instanceId: string; model: string };
  createdAt: string;
  updatedAt: string;
}

export interface EnvThread {
  id: string;
  projectId: string;
  title: string;
  modelSelection: { instanceId: string; model: string };
  runtimeMode: "full-access";
  interactionMode: "default";
  branch: string | null;
  worktreePath: string | null;
  linkedPullRequest: unknown;
  latestTurn: null;
  createdAt: string;
  updatedAt: string;
  archivedAt: string | null;
  settledOverride: "settled" | "active" | null;
  settledAt: string | null;
  unsettledAt: string | null;
  snoozedUntil: string | null;
  snoozedAt: string | null;
  pinnedAt: string | null;
  session: { status: string } | null;
  latestUserMessageAt: string | null;
  hasPendingApprovals: boolean;
  hasPendingUserInput: boolean;
  hasActionableProposedPlan: boolean;
}

export interface Environment {
  readonly projects: EnvProject[];
  threads: EnvThread[];
  /** The server settles threads (`capabilities.threadSettlement`). */
  settlement: boolean;
  /** When set, every settle is rejected with this reason. */
  settleError: string | null;
  defaultThreadEnvMode: ThreadEnvMode | null;
  /** What `listRefs` answers for every project. */
  refs: VcsRef[];
  connected: boolean;
  created: number;
}

interface EnvWorld extends World {
  env?: Environment;
}

const slug = (text: string) =>
  text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");

export function env(ctx: World): Environment {
  const world = ctx as EnvWorld;
  if (!world.env) {
    world.env = {
      projects: [],
      threads: [],
      settlement: true,
      settleError: null,
      defaultThreadEnvMode: null,
      refs: [{ name: "main", current: true, isDefault: true, worktreePath: null } as VcsRef],
      connected: false,
      created: 0,
    };
    ctx.nowMs ??= DEFAULT_NOW_MS;
  }
  return world.env;
}

const nowIso = (ctx: World) => new Date(ctx.nowMs ?? DEFAULT_NOW_MS).toISOString();

export function addProject(ctx: World, title: string): EnvProject {
  const existing = env(ctx).projects.find((project) => project.title === title);
  if (existing) return existing;
  const project: EnvProject = {
    id: `p-${slug(title)}`,
    title,
    workspaceRoot: `/work/${slug(title)}`,
    defaultModelSelection: { instanceId: "codex", model: "gpt-5" },
    createdAt: "2026-07-01T00:00:00.000Z",
    updatedAt: "2026-07-01T00:00:00.000Z",
  };
  env(ctx).projects.push(project);
  return project;
}

/** Add a thread (created one minute after the previous one) to a project, the first by default. */
export function addThread(
  ctx: World,
  title: string,
  fields: Partial<EnvThread> & { project?: string } = {},
): EnvThread {
  const environment = env(ctx);
  const { project: projectTitle, ...rest } = fields;
  const project = projectTitle
    ? addProject(ctx, projectTitle)
    : (environment.projects[0] ?? addProject(ctx, "shop"));
  environment.created += 1;
  const createdAt = new Date(CREATED_BASE_MS + environment.created * MINUTE_MS).toISOString();
  const thread: EnvThread = {
    id: `t-${slug(title) || "thread"}-${environment.created}`,
    projectId: project.id,
    title,
    modelSelection: { instanceId: "codex", model: "gpt-5" },
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath: null,
    linkedPullRequest: null,
    latestTurn: null,
    createdAt,
    updatedAt: createdAt,
    archivedAt: null,
    settledOverride: null,
    settledAt: null,
    unsettledAt: null,
    snoozedUntil: null,
    snoozedAt: null,
    pinnedAt: null,
    session: null,
    latestUserMessageAt: createdAt,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    hasActionableProposedPlan: false,
    ...rest,
  };
  environment.threads.push(thread);
  return thread;
}

export function threadNamed(ctx: World, title: string): EnvThread {
  const thread = env(ctx).threads.find((candidate) => candidate.title === title);
  if (!thread) throw new Error(`no thread "${title}" in the environment`);
  return thread;
}

export function projectNamed(ctx: World, title: string): EnvProject {
  const project = env(ctx).projects.find((candidate) => candidate.title === title);
  if (!project) throw new Error(`no project "${title}" in the environment`);
  return project;
}

function snapshotOf(environment: Environment): OrchestrationShellSnapshot {
  return {
    snapshotSequence: environment.created,
    projects: environment.projects.map((project) => ({ ...project })),
    threads: environment.threads.map((thread) => ({ ...thread })),
    updatedAt: new Date().toISOString(),
  } as unknown as OrchestrationShellSnapshot;
}

/** Change the environment; connected clients get the new snapshot. */
export function change(ctx: World, mutate: (environment: Environment) => void): void {
  const environment = env(ctx);
  mutate(environment);
  if (environment.connected) ctx.fake!.emitShell(snapshotOf(environment));
}

const errorFor = (reason: string) => Promise.reject(new Error(reason));

function installClient(ctx: World): void {
  const environment = env(ctx);
  const update = (id: unknown, patch: (thread: EnvThread) => void): Promise<void> => {
    const thread = environment.threads.find((candidate) => candidate.id === id);
    if (!thread) return errorFor(`Thread ${String(id)} not found`);
    change(ctx, () => patch(thread));
    return Promise.resolve();
  };
  useClient(ctx, {
    getServerConfig: async () =>
      ({
        settings: {
          ...DEFAULT_SERVER_SETTINGS,
          defaultThreadEnvMode: environment.defaultThreadEnvMode ?? undefined,
        },
        environment: { capabilities: { threadSettlement: environment.settlement } },
      }) as never,
    renameThread: (id, title) =>
      update(id, (thread) => {
        thread.title = title;
      }),
    archiveThread: (id) =>
      update(id, (thread) => {
        thread.archivedAt = nowIso(ctx);
      }),
    unarchiveThread: (id) =>
      update(id, (thread) => {
        thread.archivedAt = null;
      }),
    deleteThread: (id) => {
      if (!environment.threads.some((thread) => thread.id === id)) {
        return errorFor(`Thread ${String(id)} not found`);
      }
      change(ctx, (next) => {
        next.threads = next.threads.filter((thread) => thread.id !== id);
      });
      return Promise.resolve();
    },
    settleThread: (id) => {
      const thread = environment.threads.find((candidate) => candidate.id === id);
      if (environment.settleError) return errorFor(environment.settleError);
      // The server's rule: a thread that still needs the user stays active.
      if (thread?.hasPendingApprovals || thread?.hasPendingUserInput) {
        return errorFor("Thread needs attention before it can be settled");
      }
      return update(id, (next) => {
        next.settledOverride = "settled";
        next.settledAt = nowIso(ctx);
      });
    },
    unsettleThread: (id) =>
      update(id, (thread) => {
        thread.settledOverride = "active";
        thread.unsettledAt = nowIso(ctx);
      }),
    stopSession: (id) =>
      update(id, (thread) => {
        thread.session = { status: "stopped" };
      }),
    listRefs: async () =>
      ({
        refs: environment.refs,
        isRepo: true,
        hasPrimaryRemote: true,
        nextCursor: null,
        totalCount: environment.refs.length,
      }) as never,
    switchRef: async (_cwd, refName) => ({ refName }) as never,
    createThread: async (input) => {
      const project = environment.projects.find((candidate) => candidate.id === input.projectId);
      const thread = addThread(ctx, input.title, {
        ...(project ? { project: project.title } : {}),
        branch: input.branch,
        worktreePath: input.worktreePath,
        session: { status: "starting" },
      });
      change(ctx, () => {});
      return thread.id as never;
    },
  });
}

/** Wait for the client's pending promises (command replies, config) to land. */
export async function flush(ctx: World): Promise<void> {
  for (let i = 0; i < 3; i += 1) await new Promise((resolve) => setImmediate(resolve));
  if (ctx.app) await ctx.app.renderOnce();
}

/** The running client, connected to the environment (booted on first use). */
export async function ui(ctx: World) {
  // Another world (git, thread) brought its own client: boot on that instead.
  if (ctx.fake && !(ctx as EnvWorld).env) {
    const app = await boot(ctx);
    await flush(ctx);
    return app;
  }
  const environment = env(ctx);
  if (!ctx.fake) installClient(ctx);
  const app = await boot(ctx);
  if (!environment.connected) {
    environment.connected = true;
    ctx.fake!.emitShell(snapshotOf(environment));
  }
  await flush(ctx);
  return app;
}

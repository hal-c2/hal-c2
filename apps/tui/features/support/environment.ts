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

/** A machine of the cluster, as the merged shell names it. */
export interface EnvMachine {
  id: string;
  label: string;
  online: boolean;
}

/**
 * How a machine is doing when the MC asks what it has for a new thread
 * (HalC2.LoadBalancing): the share of its processors in use and of its memory
 * free, whether it answers at all, and whether its agents are signed in.
 */
export interface EnvLoad {
  cpu: number;
  free: number;
  silent?: boolean;
  signedOut?: boolean;
}

export const IDLE: EnvLoad = { cpu: 0.1, free: 0.9 };

export interface EnvProject {
  id: string;
  title: string;
  /** The machine it is on, in a cluster. */
  machine?: string;
  workspaceRoot: string;
  defaultModelSelection: { instanceId: string; model: string };
  createdAt: string;
  updatedAt: string;
}

export interface EnvThread {
  id: string;
  projectId: string;
  title: string;
  /** The machine it lives on, in a cluster. */
  machine?: string;
  /** Where it is moving to, until it arrives. */
  moving?: { label: string; environmentId: string } | null;
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
  /** The cluster's machines, this one first; empty while this machine is alone. */
  machines: EnvMachine[];
  /** How each machine is doing, by label; one not named is idle. */
  loads: Record<string, EnvLoad>;
  /** The home MC's settings document and its version (`hal-c2.readSettings`). */
  settings: Record<string, unknown>;
  settingsVersion: number;
  /** A move carries the agent's own session; otherwise the agent gets a summary. */
  sessionCarried: boolean;
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
      machines: [],
      loads: {},
      settings: {},
      settingsVersion: 0,
      sessionCarried: true,
      connected: false,
      created: 0,
    };
    ctx.nowMs ??= DEFAULT_NOW_MS;
  }
  return world.env;
}

const nowIso = (ctx: World) => new Date(ctx.nowMs ?? DEFAULT_NOW_MS).toISOString();

export function addProject(ctx: World, title: string, machine?: string): EnvProject {
  const existing = env(ctx).projects.find(
    (project) => project.title === title && project.machine === machine,
  );
  if (existing) return existing;
  const project: EnvProject = {
    id: machine ? `p-${slug(title)}-${slug(machine)}` : `p-${slug(title)}`,
    title,
    ...(machine ? { machine } : {}),
    // Each machine has its own checkout.
    workspaceRoot: machine ? `/work/${slug(machine)}/${slug(title)}` : `/work/${slug(title)}`,
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
    ...(environment.machines.length > 0
      ? { machines: environment.machines.map((machine) => ({ ...machine })) }
      : {}),
    updatedAt: new Date().toISOString(),
  } as unknown as OrchestrationShellSnapshot;
}

/** Change the environment; connected clients get the new snapshot. */
export function change(ctx: World, mutate: (environment: Environment) => void): void {
  const environment = env(ctx);
  mutate(environment);
  if (environment.connected) ctx.fake!.emitShell(snapshotOf(environment));
}

/** A thread starts moving: its row says where to until it arrives. */
export function startMoving(ctx: World, title: string, machine: string): void {
  const destination = env(ctx).machines.find((candidate) => candidate.label === machine);
  if (!destination) throw new Error(`no machine "${machine}" in the cluster`);
  change(ctx, () => {
    threadNamed(ctx, title).moving = { label: machine, environmentId: destination.id };
  });
}

/** A thread arrives: it lives in its project's checkout on `machine` from here on. */
export function arrive(ctx: World, title: string, machine: string): void {
  change(ctx, (environment) => {
    const thread = threadNamed(ctx, title);
    const from = environment.projects.find((project) => project.id === thread.projectId);
    thread.projectId = addProject(ctx, from?.title ?? "shop", machine).id;
    thread.machine = machine;
    thread.moving = null;
  });
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
  const fake = useClient(ctx, {
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
        ...(project ? { projectId: project.id } : {}),
        ...(project?.machine ? { machine: project.machine } : {}),
        branch: input.branch,
        worktreePath: input.worktreePath,
        session: { status: "starting" },
      });
      change(ctx, () => {});
      return thread.id as never;
    },
  });
  fake.override("interrupt", (id) =>
    update(id, (thread) => {
      thread.session = { status: "ready" };
    }),
  );
  // The MC that holds a thread moves it, under the rules of HalC2.ThreadMove.
  fake.override("moveDestinations", async (id) => {
    const thread = environment.threads.find((candidate) => candidate.id === id);
    const title = environment.projects.find((project) => project.id === thread?.projectId)?.title;
    return environment.machines
      .filter((machine) => machine.label !== thread?.machine)
      .map((machine) => ({
        machine: machine.label,
        environmentId: machine.id,
        online: machine.online,
        projects: environment.projects
          .filter((project) => machine.online && project.machine === machine.label)
          .map((project) => ({
            id: project.id,
            title: project.title,
            workspaceRoot: project.workspaceRoot,
            sameRepository: project.title === title,
          })),
      }));
  });
  // The home MC chooses where a new thread starts, under the rules of
  // HalC2.LoadBalancing: of the machines that answer with a checkout of the
  // repository and the agent ready, the one with the most room by its weight.
  fake.override("placeThread", async ({ environmentId, projectId, instanceId }) => {
    const picked = environment.projects.find((project) => project.id === projectId);
    let placement = { environmentId, projectId };
    if (environment.settings.loadBalancingEnabled !== true || !picked) return placement;
    const weights = (environment.settings.loadBalancingWeights ?? {}) as Record<string, number>;
    let best = 0;
    for (const machine of environment.machines) {
      const load = environment.loads[machine.label] ?? IDLE;
      const checkout = environment.projects.find(
        (project) => project.machine === machine.label && project.title === picked.title,
      );
      const ready = instanceId === undefined || !load.signedOut;
      if (!machine.online || load.silent || !checkout || !ready) continue;
      if (load.cpu >= 0.95 || load.free <= 0.05) continue;
      const score = (weights[machine.id] ?? 50) * (1 - load.cpu) * load.free;
      // The user's own pick wins a tie, and keeps the checkout they picked.
      const own = machine.id === environmentId;
      if (score > best || (score === best && own)) {
        best = score;
        placement = { environmentId: machine.id, projectId: own ? projectId : checkout.id };
      }
    }
    return placement;
  });
  fake.override("readSettings", async () => ({
    settings: { ...environment.settings },
    version: environment.settingsVersion,
  }));
  fake.override("writeSettings", async (settings, version) => {
    if (version !== environment.settingsVersion) return false;
    environment.settings = { ...settings };
    environment.settingsVersion += 1;
    return true;
  });
  fake.override("moveThread", async ({ threadId, machine }) => {
    const thread = environment.threads.find((candidate) => candidate.id === threadId);
    const destination = environment.machines.find((candidate) => candidate.label === machine);
    if (!thread || !destination) throw new Error(`Thread ${threadId} not found`);
    const { title } = thread;
    if (thread.session?.status === "running") {
      throw new Error(`${title} is running. Stop it or wait for it to finish before moving it.`);
    }
    if (!destination.online) throw new Error(`${machine} is offline. ${title} was not moved.`);
    startMoving(ctx, title, machine);
    arrive(ctx, title, machine);
    return {
      status: "moved",
      threadId,
      machine,
      environmentId: destination.id,
      projectId: thread.projectId,
      sessionCarried: environment.sessionCarried,
      message: `${title} moved to ${machine}. ${
        environment.sessionCarried
          ? "The agent continues its own session there."
          : "The agent there will get a summary of the conversation."
      }`,
      notes: [],
    };
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

// The MC's side of a project for features/files/: what `projects.mutate`
// changes and the checkout's files (hal-c2.json, sources). It sits on the environment of environment.ts, so a change
// reaches the client as a fresh shell snapshot, as from the real MC.
import type { ProjectScript } from "@hal-c2/contracts";

import { change, env, projectNamed, type EnvProject } from "./environment.ts";
import type { World } from "./world.ts";

export type ScriptedProject = EnvProject & {
  scripts?: ProjectScript[];
  defaultThreadEnvMode?: "local" | "worktree" | null;
};

export interface ProjectsMc {
  /** The MC's reason for refusing `projects.mutate`; null accepts. */
  refusal: string | null;
  /** Every `projects.mutate` the client sent, oldest first. */
  readonly mutations: Array<Record<string, any>>;
  /** Files by `<workspace root>/<relative path>`. */
  readonly files: Map<string, string>;
  /** Paths the MC refuses to read or write, with its reason. */
  readonly unreadable: Map<string, string>;
}

interface ProjectsWorld extends World {
  projectsMc?: ProjectsMc;
}

export const scriptsOf = (ctx: World, title: string): ProjectScript[] =>
  ((projectNamed(ctx, title) as ScriptedProject).scripts ??= []);

function install(ctx: ProjectsWorld, mc: ProjectsMc): void {
  const fake = ctx.fake!;
  fake.settings.on("projects.mutate", (payload) => {
    mc.mutations.push(payload);
    if (mc.refusal !== null) throw new Error(mc.refusal);
    const environment = env(ctx);
    const project = environment.projects.find((entry) => entry.id === payload.projectId);
    if (!project) throw new Error(`unknown project ${payload.projectId}`);
    if (payload.type === "project.update") {
      const { type: _type, projectId: _id, ...fields } = payload;
      change(ctx, () => Object.assign(project, fields));
    } else if (payload.type === "project.delete") {
      change(ctx, (next) => {
        next.projects.splice(next.projects.indexOf(project), 1);
        next.threads = next.threads.filter((thread) => thread.projectId !== project.id);
      });
    } else throw new Error(`${payload.type} is not supported`);
    return project;
  });
  fake.override("readFile", (async (cwd: string, relativePath: string) => {
    const path = `${cwd}/${relativePath}`;
    if (mc.unreadable.has(path)) return null;
    return mc.files.get(path) ?? null;
  }) as never);
}

/** The project side of the fake MC, installed on the environment's client before boot. */
export function projectsMc(ctx: ProjectsWorld): ProjectsMc {
  if (ctx.projectsMc) return ctx.projectsMc;
  const mc: ProjectsMc = {
    refusal: null,
    mutations: [],
    files: new Map(),
    unreadable: new Map(),
  };
  ctx.projectsMc = mc;
  // Makes the environment (and its pinned clock) before anything boots.
  env(ctx);
  if (ctx.app) install(ctx, mc);
  else {
    const previous = ctx.prepare;
    ctx.prepare = () => {
      previous?.();
      install(ctx, mc);
    };
  }
  return mc;
}

/** Put a file in a project's checkout. */
export function writeProjectFile(ctx: World, project: string, path: string, contents: string) {
  projectsMc(ctx).files.set(`${projectNamed(ctx, project).workspaceRoot}/${path}`, contents);
}

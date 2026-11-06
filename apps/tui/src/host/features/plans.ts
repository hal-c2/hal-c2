import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import type { OrchestrationThread } from "@hal-c2/contracts";

import { clip } from "../../format.ts";
import { findLatestProposedPlan, proposedPlanTitle } from "../../proposedPlan.ts";
import { THEME } from "../../theme.ts";
import { threadKey } from "../sidebarState.ts";
import { chunk, styled, type StyledText } from "../styledText.ts";
import { errorText, payloadField, type Feature, type FeatureKit } from "./kit.ts";

type StepStatus = "pending" | "inProgress" | "completed";

/** Published under `planStatus` (null with nothing to show): lines under the conversation. */
export interface TuiPlanStatusState {
  readonly lines: ReadonlyArray<{
    readonly text: StyledText;
    /** The action a click dispatches ("" for none). */
    readonly action: string;
    readonly payload: unknown;
  }>;
  /** The agent's step list, for the lines above. */
  readonly steps: ReadonlyArray<{ readonly step: string; readonly status: StepStatus }>;
  /** The thread that implemented the latest plan, when it is another one. */
  readonly implementedIn: { readonly key: string; readonly title: string } | null;
}

const STEP_GLYPH: Record<StepStatus, string> = { completed: "✓", inProgress: "⟳", pending: "○" };

/** `# Fix the cart total` → `fix-the-cart-total.md` (the web client's file name). */
export function planFileName(planMarkdown: string): string {
  const segment = (proposedPlanTitle(planMarkdown) ?? "plan")
    .toLowerCase()
    .replace(/[`'".,!?()[\]{}]+/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `${segment || "plan"}.md`;
}

/** The plan as the web client exports it: its Markdown with one closing newline. */
const planText = (planMarkdown: string) => `${planMarkdown.trimEnd()}\n`;

/** The first message of a thread that implements a plan (the web client's prompt). */
export const planImplementationPrompt = (planMarkdown: string) =>
  `PLEASE IMPLEMENT THIS PLAN:\n${planMarkdown.trim()}`;

/** Write `name` into `dir` without overwriting: `plan.md`, then `plan (2).md`, … */
export function writeNewFile(dir: string, name: string, text: string): string {
  NodeFS.mkdirSync(dir, { recursive: true });
  const ext = NodePath.extname(name);
  const stem = name.slice(0, name.length - ext.length);
  for (let n = 1; ; n += 1) {
    const file = NodePath.join(dir, n === 1 ? name : `${stem} (${n})${ext}`);
    try {
      NodeFS.writeFileSync(file, text, { flag: "wx" });
      return file;
    } catch (error) {
      if ((error as { code?: string }).code !== "EEXIST") throw error;
    }
  }
}

export interface PlansOptions {
  /** Where "Download plan" writes on this machine (the user's Downloads folder). */
  readonly downloadsDir: string;
}

function latestSteps(detail: OrchestrationThread) {
  const update = detail.activities.findLast((activity) => activity.kind === "turn.plan.updated");
  const plan = (update?.payload as { plan?: unknown } | undefined)?.plan;
  if (!Array.isArray(plan)) return [];
  return plan.flatMap((entry: { step?: unknown; status?: unknown }) =>
    typeof entry.step === "string" &&
    (entry.status === "pending" || entry.status === "inProgress" || entry.status === "completed")
      ? [{ step: entry.step, status: entry.status as StepStatus }]
      : [],
  );
}

/**
 * Plans beyond the proposal card: the agent's step list as it works through
 * it, the thread an implemented plan went to, and the plan as a Markdown file
 * in the workspace (or on the clipboard).
 */
export function createPlansFeature(kit: FeatureKit, options: PlansOptions): Feature {
  const { client, store } = kit;
  let last = "";

  const detail = () => store.getState().detail;
  const latestPlan = () => {
    const current = detail();
    return current
      ? findLatestProposedPlan(current.proposedPlans, current.latestTurn?.turnId ?? null)
      : null;
  };
  const implementedIn = () => {
    const current = detail();
    const plan = latestPlan();
    const id = plan?.implementationThreadId ?? null;
    if (!current || id === null || id === current.id) return null;
    const title =
      store.getState().shell?.threads.find((thread) => thread.id === id)?.title ?? (id as string);
    return { key: threadKey(id), title };
  };

  const build = (): TuiPlanStatusState | null => {
    const current = detail();
    if (!current) return null;
    const steps = latestSteps(current);
    const link = implementedIn();
    if (steps.length === 0 && link === null) return null;
    const lines: Array<TuiPlanStatusState["lines"][number]> = [];
    if (steps.length > 0) {
      const done = steps.filter((step) => step.status === "completed").length;
      lines.push({
        text: styled(
          chunk("◆ ", { fg: THEME.accent }),
          chunk("Plan", { bold: true }),
          chunk(` · ${done}/${steps.length} done`, { fg: THEME.dim }),
        ),
        action: "",
        payload: null,
      });
      for (const step of steps) {
        lines.push({
          text: styled(
            chunk(`  ${STEP_GLYPH[step.status]} `, {
              fg:
                step.status === "completed"
                  ? THEME.success
                  : step.status === "inProgress"
                    ? THEME.accent
                    : THEME.faint,
            }),
            chunk(clip(step.step, 200), {
              fg: step.status === "pending" ? THEME.dim : THEME.text,
              ...(step.status === "inProgress" ? { bold: true } : {}),
            }),
          ),
          action: "",
          payload: null,
        });
      }
    }
    if (link) {
      lines.push({
        text: styled(
          chunk("◆ ", { fg: THEME.success }),
          chunk("Plan implemented in ", { fg: THEME.dim }),
          chunk(link.title, { fg: THEME.accent, underline: true }),
        ),
        action: "thread.open",
        payload: { key: link.key },
      });
    }
    return { lines, steps, implementedIn: link };
  };

  const publish = () => {
    const next = build();
    const json = JSON.stringify(next);
    if (json === last) return;
    last = json;
    kit.state.set("planStatus", next);
  };

  // The thread's worktree, else its project's folder; null when the MC knows neither.
  const workspaceOrSay = () => {
    const current = detail();
    const cwd =
      current?.worktreePath ??
      store.getState().shell?.projects.find((p) => p.id === current?.projectId)?.workspaceRoot ??
      null;
    if (cwd === null) kit.status("Workspace path is unavailable", "error");
    return cwd;
  };

  // The workspace may be another machine's: the MC writes the file there.
  const save = (path: string) => {
    const plan = latestPlan();
    const cwd = workspaceOrSay();
    if (!plan || cwd === null) return;
    void kit.track(
      client.writeFile(cwd, path, planText(plan.planMarkdown)).then(
        () => kit.status(`Plan saved to ${path}.`, "success"),
        (error: unknown) => kit.status(`Could not save the plan: ${errorText(error)}`, "error"),
      ),
    );
  };

  const askSave = () => {
    const plan = latestPlan();
    if (!plan || workspaceOrSay() === null) return;
    kit.ask({
      label: "save plan to",
      placeholder: "path in the workspace",
      value: planFileName(plan.planMarkdown),
      onSubmit: (path) => {
        if (path.length > 0) save(path);
      },
    });
  };

  const download = () => {
    const plan = latestPlan();
    if (!plan) return;
    try {
      const file = writeNewFile(
        options.downloadsDir,
        planFileName(plan.planMarkdown),
        planText(plan.planMarkdown),
      );
      kit.status(`Plan downloaded to ${file}.`, "success");
    } catch (error) {
      kit.status(`Could not download the plan: ${errorText(error)}`, "error");
    }
  };

  // A new thread in default mode, on the planning thread's branch and model,
  // starts with the plan; the MC marks the plan implemented by it.
  const implementInNewThread = () => {
    const current = detail();
    const plan = latestPlan();
    if (!current || !plan) return;
    const project = store.getState().shell?.projects.find((p) => p.id === current.projectId);
    if (!project) {
      kit.status("Could not start implementation thread", "error");
      return;
    }
    const title = proposedPlanTitle(plan.planMarkdown);
    kit.status("Starting implementation thread…", "busy");
    void kit.track(
      client
        .createThread({
          projectId: current.projectId,
          projectCwd: project.workspaceRoot,
          title: title ? `Implement ${title}` : "Implement plan",
          modelSelection: current.modelSelection,
          firstMessage: planImplementationPrompt(plan.planMarkdown),
          attachments: [],
          runtimeMode: current.runtimeMode,
          interactionMode: "default",
          branch: current.branch,
          worktreePath: current.worktreePath,
          createWorktree: false,
          startFromOrigin: false,
          sourceProposedPlan: { threadId: current.id, planId: plan.id },
        })
        .then(
          (threadId) => {
            store.select({ kind: "thread", id: threadId });
            kit.status("Implementation thread started.", "success");
          },
          // The web client's toast title; the status line has room for no more.
          () => kit.status("Could not start implementation thread", "error"),
        ),
    );
  };

  kit.state.set("planStatus", null);
  return {
    sync: publish,
    commands: () => {
      const link = implementedIn();
      return [
        ...(latestPlan()
          ? [
              {
                id: "plan.implementInNewThread",
                title: "Implement plan in a new thread",
                keywords: "proposed plan start",
                action: "plan.implementInNewThread",
              },
              {
                id: "plan.save",
                title: "Save plan as Markdown",
                keywords: "export file write",
                action: "plan.save",
              },
              {
                id: "plan.copy",
                title: "Copy plan as Markdown",
                keywords: "clipboard export",
                action: "plan.copy",
              },
              {
                id: "plan.download",
                title: "Download plan as Markdown",
                keywords: "export file downloads",
                action: "plan.download",
              },
            ]
          : []),
        ...(link
          ? [
              {
                id: "plan.openImplementation",
                title: `Open the thread that implemented the plan`,
                keywords: `implementation ${link.title}`,
                action: "thread.open",
                payload: { key: link.key },
              },
            ]
          : []),
      ];
    },
    dispatch: (action, payload) => {
      switch (action) {
        case "plan.implementInNewThread":
          implementInNewThread();
          return true;
        case "plan.save": {
          // A path in the payload saves there; without one the user is asked.
          const path = payloadField(payload, "path");
          if (typeof path === "string" && path.trim().length > 0) save(path.trim());
          else askSave();
          return true;
        }
        case "plan.download":
          download();
          return true;
        case "plan.copy": {
          const plan = latestPlan();
          if (!plan) return true;
          const copied = kit.copy(planText(plan.planMarkdown));
          kit.status(
            copied ? "Plan copied." : "This terminal has no clipboard access.",
            copied ? "success" : "warning",
          );
          return true;
        }
        default:
          return false;
      }
    },
  };
}

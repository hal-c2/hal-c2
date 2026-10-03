import type { OrchestrationThread } from "@hal-c2/contracts";

import { clip } from "../../format.ts";
import { findLatestProposedPlan, proposedPlanTitle } from "../../proposedPlan.ts";
import { THEME } from "../../theme.ts";
import { threadKey } from "../sidebarState.ts";
import { chunk, styled, type StyledText } from "../styledText.ts";
import { errorText, type Feature, type FeatureKit } from "./kit.ts";

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
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `${segment || "plan"}.md`;
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
export function createPlansFeature(kit: FeatureKit): Feature {
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

  const save = () => {
    const plan = latestPlan();
    const workspace = kit.workspace();
    if (!plan || !workspace) {
      kit.status("This thread has no plan to save.", "error");
      return;
    }
    const name = planFileName(plan.planMarkdown);
    void kit.track(
      client.writeFile(workspace.cwd, name, `${plan.planMarkdown.trimEnd()}\n`).then(
        () => kit.status(`Plan saved to ${name}.`, "success"),
        (error: unknown) => kit.status(`Could not save the plan: ${errorText(error)}`, "error"),
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
    dispatch: (action) => {
      switch (action) {
        case "plan.save":
          save();
          return true;
        case "plan.copy": {
          const plan = latestPlan();
          if (!plan) return true;
          const copied = kit.copy(`${plan.planMarkdown.trimEnd()}\n`);
          kit.status(
            copied ? "Plan copied." : "This terminal has no clipboard access.",
            copied ? "success" : "error",
          );
          return true;
        }
        default:
          return false;
      }
    },
  };
}

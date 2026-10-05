// tui/approvals.feature: the agent's step list, a plan saved as Markdown, and
// the thread an implemented plan went to.
import { expect } from "bun:test";

import type { TuiPlanStatusState } from "../../../src/host/features/plans.ts";
import { THEME } from "../../../src/theme.ts";
import { step } from "../../steps.ts";
import { expectColour, objectRows, rectOf, textWithin } from "../design.ts";
import { project, shell } from "../fakeClient.ts";
import { chooseCommand } from "../threadUi.ts";
import {
  activity,
  clickText,
  latestTurn,
  plan,
  updateThread,
  type ThreadWorld,
} from "../threadWorld.ts";
import { settle, type World } from "../world.ts";

const planStatus = (ctx: World) => ctx.host!.state.get("planStatus") as TuiPlanStatusState | null;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };

const STEPS = [
  { step: "Read the cart module", status: "completed" },
  { step: "Add a cache layer", status: "completed" },
  { step: "Invalidate on write", status: "inProgress" },
  { step: "Cover it with tests", status: "pending" },
  { step: "Update the docs", status: "pending" },
] as const;

step("the agent is implementing a plan with five steps", async (ctx: ThreadWorld) => {
  // The agent reports its list again as each step starts: the newest report is the one shown.
  const report = (id: string, seconds: number, done: number) =>
    activity(id, seconds, {
      tone: "info",
      kind: "turn.plan.updated",
      summary: "Updated plan",
      turnId: "turn-1",
      payload: {
        explanation: null,
        plan: STEPS.map((entry, index) => ({
          step: entry.step,
          status: index < done ? "completed" : index === done ? "inProgress" : "pending",
        })),
      },
    });
  await updateThread(ctx, (detail) => ({
    session: { status: "running" } as never,
    latestTurn: latestTurn("turn-1", 0),
    activities: [...detail.activities, report("plan-a", 1, 0), report("plan-b", 2, 2)],
  }));
  await settle(ctx);
});

step("the plan shows which steps are done, in progress and pending", async (ctx: World) => {
  expect(planStatus(ctx)?.steps).toEqual([...STEPS]);
  const rows = (await objectRows(ctx, "planStatus")).map((row) => row.trim());
  expect(rows).toEqual([
    "◆ Plan · 2/5 done",
    "✓ Read the cart module",
    "✓ Add a cache layer",
    "⟳ Invalidate on write",
    "○ Cover it with tests",
    "○ Update the docs",
  ]);
  // The three states read apart by colour as well as by glyph.
  const inner = rectOf(ctx, "planStatus");
  expectColour((await textWithin(ctx, inner, "✓")).span.fg, THEME.success);
  expectColour((await textWithin(ctx, inner, "⟳")).span.fg, THEME.accent);
  expectColour((await textWithin(ctx, inner, "○")).span.fg, THEME.faint);
  expectColour((await textWithin(ctx, inner, "Cover it with tests")).span.fg, THEME.dim);
});

step("the user saves the plan as Markdown", async (ctx: ThreadWorld) => {
  await chooseCommand(ctx, "Save plan as Markdown");
  await settle(ctx);
});

step("a Markdown file with the plan is written to the workspace", async (ctx: ThreadWorld) => {
  const markdown = ctx.thread!.proposedPlans[0]!.planMarkdown;
  // Named after the plan's title, in the thread's workspace, the whole plan.
  expect(ctx.fake!.calls.filter((call) => call.method === "writeFile")).toEqual([
    {
      method: "writeFile",
      args: [project.workspaceRoot, "add-caching.md", `${markdown.trimEnd()}\n`],
    },
  ]);
  expect(markdown).toStartWith("# Add caching");
  expect(status(ctx)).toEqual({ kind: "success", text: "Plan saved to add-caching.md." });
});

step("the plan was implemented in another thread", async (ctx: ThreadWorld) => {
  const [open] = shell().threads;
  ctx.fake!.emitShell(
    shell([open!, { ...open!, id: "t-impl" as never, title: "Implement Add caching" }] as never),
  );
  await updateThread(ctx, () => ({
    proposedPlans: [
      plan("plan-1", "# Add caching\n\nCache the product list.", 5, {
        implementedAt: new Date().toISOString(),
        implementationThreadId: "t-impl",
      } as never),
    ],
  }));
  await settle(ctx);
});

step("the plan names that thread and the user can open it", async (ctx: ThreadWorld) => {
  expect(planStatus(ctx)?.implementedIn).toEqual({
    key: "local:t-impl",
    title: "Implement Add caching",
  });
  const rows = (await objectRows(ctx, "planStatus")).map((row) => row.trim());
  expect(rows).toEqual(["◆ Plan implemented in Implement Add caching"]);
  // From the keyboard too: the palette offers it.
  const palette = () =>
    ctx.host!.state.get("page") as { kind: string; threadId?: string; title?: string };
  expect(palette().threadId).toBe("t1");
  await clickText(ctx, "Plan implemented in");
  await settle(ctx);
  expect(palette()).toMatchObject({ kind: "thread", threadId: "t-impl" });
  ctx.host!.dispatch("thread.open", { key: "local:t1" });
  await settle(ctx);
  await chooseCommand(ctx, "Open the thread that implemented the plan");
  await settle(ctx);
  expect(palette()).toMatchObject({ kind: "thread", threadId: "t-impl" });
});

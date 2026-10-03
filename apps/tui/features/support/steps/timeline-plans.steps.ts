// features/timeline/plans-and-subagents.feature on the terminal client: the
// plan card, subagent rows and context markers, over the MC's projection
// (turnWorld.ts). The fake MC answers "implement" and a reply as the real one does.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { findObject, pressKey, settle as settleHost, snapshot, typeText } from "../world.ts";
import { hostState, plain, recorded, settle } from "../threadWorld.ts";
import {
  addItem,
  currentRun,
  lastOf,
  setThread,
  settleRun,
  startRun,
  sync,
  turns,
  type ShownLine,
  type TurnWorld,
} from "../turnWorld.ts";

interface PlanWorld extends TurnWorld {
  planId?: string;
}

const PLAN = "# Add a tax line\n\n- Add the line\n- Test it";
const REVISED = "# Add a tax line in two steps\n\n- Migrate the schema\n- Add the line";

const planCard = (ctx: TurnWorld) =>
  hostState(ctx, "timeline").plan as {
    id: string;
    title: ShownLine["text"];
    lines: ShownLine["text"][];
  } | null;

// --- the plan card ---------------------------------------------------------------------

step(
  "the agent proposes a plan whose first heading is {string}",
  async (ctx: PlanWorld, heading: string) => {
    await startRun(ctx);
    await addItem(ctx, "proposed_plan", {
      markdown: `Here is the plan.\n\n## ${heading}\n\n- Add the line\n- Test it`,
    });
  },
);

step(
  "the agent proposes a plan that opens with the heading {string}",
  async (ctx: PlanWorld, heading: string) => {
    await startRun(ctx);
    await addItem(ctx, "proposed_plan", {
      markdown: `# ${heading}\n\n## Summary\n\n- Add the line\n- Test it`,
    });
  },
);

async function expectTitled(ctx: PlanWorld, title: string) {
  expect(findObject(ctx, "planCard").get("visible")).toBe(true);
  expect(plain(planCard(ctx)!.title)).toBe(`◆ ${title}`);
  expect(await snapshot(ctx)).toContain(`◆ ${title}`);
}

step("the plan card is titled {string}", expectTitled);

step("a plan without a heading is titled {string}", async (ctx: PlanWorld, title: string) => {
  await addItem(ctx, "proposed_plan", { markdown: "Add the line, then test it." });
  await expectTitled(ctx, title);
});

step("the plan's text starts with {string}", async (ctx: PlanWorld, text: string) => {
  const card = planCard(ctx)!;
  expect(plain(card.lines[0]!)).toBe(text);
  const screen = await snapshot(ctx);
  // The title is on the card once: the body does not repeat it.
  expect(screen.split(plain(card.title).slice(2))).toHaveLength(2);
  expect(screen).toContain(text);
});

// --- implementing and refining ---------------------------------------------------------

// A plan-mode turn ended with a plan.
step("the agent has proposed a plan", async (ctx: PlanWorld) => {
  await setThread(ctx, { interactionMode: "plan" });
  await startRun(ctx, 60);
  ctx.planId = "plan-tax";
  await addItem(ctx, "proposed_plan", { planId: ctx.planId, markdown: PLAN });
  await settleRun(ctx, "completed", 30);
  expect(plain(planCard(ctx)!.title)).toBe("◆ Add a tax line");
  expect(hostState(ctx, "threadHints").items).toContain("^Y implement");
});

step("the user implements the plan with no feedback", async (ctx: PlanWorld) => {
  // The MC leaves plan mode and starts a turn that carries the plan out.
  ctx.respond!.implementPlan = async (_thread, planId) => {
    const fixture = await turns(ctx);
    const plan = fixture.plans.find((entry) => entry.id === planId)!;
    plan.status = "completed";
    fixture.thread = { ...fixture.thread, interactionMode: "default" };
    await startRun(ctx);
    fixture.runs.at(-1)!.sourcePlanRef = { threadId: ctx.thread!.id, planId };
    await sync(ctx);
  };
  await pressKey(ctx, "Ctrl+Y");
  await settle();
});

step("the agent starts implementing it in this thread", async (ctx: PlanWorld) => {
  await settleHost(ctx);
  const calls = recorded(ctx, "implementPlan") as Array<[{ id: string }, string]>;
  expect(calls.map(([thread, planId]) => [thread.id, planId])).toEqual([["t1", ctx.planId!]]);
  expect(ctx.thread!.latestTurn).toMatchObject({
    turnId: currentRun(ctx),
    state: "running",
    sourceProposedPlan: { threadId: "t1", planId: ctx.planId },
  });
  expect(await snapshot(ctx)).toContain("● Working…");
});

step("the plan card is no longer offered", async (ctx: PlanWorld) => {
  expect(planCard(ctx)).toBeNull();
  expect(findObject(ctx, "planCard").get("visible")).toBe(false);
  expect(hostState(ctx, "threadHints").items).not.toContain("^Y implement");
  expect(await snapshot(ctx)).not.toContain("◆ Add a tax line");
});

step("the user sends {string} as feedback", async (ctx: PlanWorld, feedback: string) => {
  // The MC runs the reply as another plan-mode turn, which proposes the plan again.
  ctx.fake!.override("sendReply", async () => {
    const fixture = await turns(ctx);
    fixture.plans.find((entry) => entry.id === ctx.planId)!.status = "superseded";
    await startRun(ctx, 20);
    await addItem(ctx, "proposed_plan", { planId: "plan-revised", markdown: REVISED });
    await settleRun(ctx, "completed", 20);
  });
  await typeText(ctx, feedback);
  await pressKey(ctx, "Enter");
  await settleHost(ctx);
});

step("the agent revises the plan", async (ctx: PlanWorld) => {
  const sent = recorded(ctx, "sendReply") as Array<
    [{ id: string; interactionMode: string }, string]
  >;
  expect(sent).toHaveLength(1);
  const [thread, text] = sent[0]!;
  expect({ id: thread.id, interactionMode: thread.interactionMode, text }).toEqual({
    id: "t1",
    interactionMode: "plan",
    text: "split the migration into its own step",
  });
  expect(planCard(ctx)).toMatchObject({ id: "plan-revised" });
  expect(await snapshot(ctx)).toContain("◆ Add a tax line in two steps");
});

step("the thread stays in plan mode", async (ctx: PlanWorld) => {
  expect(recorded(ctx, "implementPlan")).toEqual([]);
  expect(recorded(ctx, "setInteractionMode")).toEqual([]);
  expect(ctx.thread!.interactionMode).toBe("plan");
  expect(plain(hostState(ctx, "timeline").header.right.text)).toContain("· plan");
  expect(await snapshot(ctx)).toContain("· plan");
});

// --- subagents -------------------------------------------------------------------------

const SUBAGENT = {
  id: "subagent",
  subagentId: "task-1",
  origin: "app_owned",
  driver: "codex",
  providerInstanceId: "codex",
  childThreadId: "thread-child",
  title: "Tax tests",
  prompt: "write the tax tests",
  result: null,
};

const SUBAGENT_STATUS: Record<string, string> = {
  running: "running",
  "waiting on a request": "waiting",
  "idle and resumable": "idle",
  completed: "completed",
  failed: "failed",
  cancelled: "cancelled",
};

function subagentRow(ctx: TurnWorld) {
  const row = lastOf(ctx, "work").lines.find((line) => plain(line.text).includes(SUBAGENT.title));
  if (!row) throw new Error("the timeline shows no subagent");
  return row;
}

step(/^the agent has a subagent that is (.+)$/, async (ctx: PlanWorld, status: string) => {
  const itemStatus = SUBAGENT_STATUS[status];
  if (!itemStatus) throw new Error(`unknown subagent status: ${status}`);
  await startRun(ctx);
  await addItem(ctx, "subagent", { ...SUBAGENT, status: itemStatus });
});

step("the subagent is shown as {string}", async (ctx: PlanWorld, label: string) => {
  // icon, title, then the status glyph and words.
  const [, title, mark] = subagentRow(ctx).text.chunks;
  expect(title!.text).toBe(SUBAGENT.title);
  expect(mark!.text.trim().split(" ").slice(1).join(" ")).toBe(label);
  expect(await snapshot(ctx)).toContain(`${SUBAGENT.title}${mark!.text}`);
});

step(
  "the agent delegated work to a subagent on the model {string}",
  async (ctx: PlanWorld, model: string) => {
    await startRun(ctx);
    // The MC lists the task with the model it was delegated to (delegation.ex).
    (await turns(ctx)).subagents.push({ id: SUBAGENT.subagentId, model, status: "running" });
    await addItem(ctx, "subagent", { ...SUBAGENT, status: "running" });
  },
);

step("the user looks at the parent's subagents", async (ctx: PlanWorld) => {
  expect(await snapshot(ctx)).toContain(SUBAGENT.title);
});

step("the subagent is shown with {string}", async (ctx: PlanWorld, model: string) => {
  const row = plain(subagentRow(ctx).text);
  expect(row).toContain(`${model} · ${SUBAGENT.prompt}`);
  expect(await snapshot(ctx)).toContain(`${model} · ${SUBAGENT.prompt}`);
});

step("the parent's model is not shown for it", async (ctx: PlanWorld) => {
  const parentModel = ctx.thread!.modelSelection.model;
  expect(parentModel).toBe("gpt-5");
  expect(plain(subagentRow(ctx).text)).not.toContain(parentModel);
});

// --- context markers -------------------------------------------------------------------

const CONTEXT_EVENTS: Record<string, [type: string, fields: Record<string, unknown>]> = {
  "the conversation is forked": [
    "fork",
    { source: { type: "run", threadId: "t1", runId: "run-1" }, targetThreadId: "thread-2" },
  ],
  "the context is handed to another agent": [
    "handoff",
    {
      contextHandoffId: "handoff-1",
      fromProviderThreadIds: [],
      toProviderThreadId: "provider-thread-2",
      fromProviderInstanceIds: ["codex"],
      toProviderInstanceId: "claude",
      strategy: "full_thread_summary",
      summary: "Cart tax so far",
    },
  ],
  "the agent creates a thread": [
    "thread_created",
    {
      targetThreadId: "thread-2",
      targetRunId: null,
      targetProviderInstanceId: "codex",
      targetModel: "gpt-5",
    },
  ],
  "the context is compacted": ["compaction", { driver: "codex", summary: "Earlier turns" }],
};

step(
  new RegExp(`^(${Object.keys(CONTEXT_EVENTS).join("|")})$`),
  async (ctx: PlanWorld, event: string) => {
    await startRun(ctx);
    await addItem(ctx, ...CONTEXT_EVENTS[event]!);
  },
);

step("the timeline marks {string}", async (ctx: PlanWorld, marker: string) => {
  const row = lastOf(ctx, "work").lines.at(-1)!;
  // icon, then the marker's title.
  expect(row.text.chunks[1]!.text).toBe(marker);
  expect(await snapshot(ctx)).toContain(marker);
});

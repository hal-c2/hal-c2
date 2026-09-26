// Steps for what the agent needs from the user (features/tui/approvals.feature,
// composer/question-answers.feature): approvals, questions and plans.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { findObject, pressKey, snapshot, typeText } from "../world.ts";
import {
  activity,
  approvalRequest,
  approvalResolved,
  deferred,
  hostState,
  latestTurn,
  openThread,
  plain,
  plan,
  questionRequest,
  recorded,
  settle,
  updateThread,
  type QuestionFixture,
  type ThreadWorld,
} from "../threadWorld.ts";

interface AnswerWorld extends ThreadWorld {
  typedAnswer?: string;
  failAnswer?: (error: unknown) => void;
}

step("the terminal client is open on a thread with focus in the prompt", async (ctx: ThreadWorld) => {
  await openThread(ctx);
  expect(hostState(ctx, "mode")).toBe("compose");
});

// --- approvals --------------------------------------------------------------------

const RUNNING = () => ({
  session: { status: "running" } as never,
  latestTurn: latestTurn("turn-1", 0),
});

async function askApprovals(ctx: ThreadWorld, commands: ReadonlyArray<string>) {
  await updateThread(ctx, () => ({
    ...RUNNING(),
    activities: commands.map((detail, index) => approvalRequest(`r${index + 1}`, detail, index + 1)),
  }));
}

step("the agent asks to run {string}", async (ctx: ThreadWorld, command: string) => {
  await askApprovals(ctx, [command]);
});

step("the agent has three pending approvals", async (ctx: ThreadWorld) => {
  await askApprovals(ctx, ["rm -rf build", "git push", "npm publish"]);
});

step("the key hints offer {string}", async (ctx: ThreadWorld, hint: string) => {
  expect(hostState(ctx, "threadHints").items).toContain(hint);
  expect(await snapshot(ctx)).toContain(hint);
});

step("the key hints do not offer {string}", async (ctx: ThreadWorld, hint: string) => {
  expect(hostState(ctx, "threadHints").items).not.toContain(hint);
  expect(await snapshot(ctx)).not.toContain(hint);
});

step("the request is approved", async (ctx: ThreadWorld) => {
  await settle();
  expect(recorded(ctx, "approve")).toEqual([["t1", "r1", "accept"]]);
});

step("the request is declined", async (ctx: ThreadWorld) => {
  await settle();
  expect(recorded(ctx, "approve")).toEqual([["t1", "r1", "decline"]]);
});

step("the user approves it and the request fails", async (ctx: ThreadWorld) => {
  ctx.respond!.approve = async () => {
    throw new Error("provider offline");
  };
  await pressKey(ctx, "Ctrl+A");
  await settle();
});

step("the status line says the approval failed", async (ctx: ThreadWorld) => {
  const status = hostState(ctx, "status");
  expect(status).toEqual({ kind: "error", text: "Approval failed: provider offline" });
  expect(await snapshot(ctx)).toContain("Approval failed: provider offline");
  expect(await snapshot(ctx)).not.toContain("Approved.");
});

step("the request stays pending", async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "approvals").count).toBe(1);
  expect(findObject(ctx, "approvals").get("visible")).toBe(true);
  expect(await snapshot(ctx)).toContain("▸ command: rm -rf build");
});

step("the timeline shows that three approvals are pending", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("pending approval");
  expect(screen).toContain("Approval required  (1 of 3)");
  for (const command of ["rm -rf build", "git push", "npm publish"]) {
    expect(screen).toContain(`command: ${command}`);
  }
});

const expectHighlighted = async (ctx: ThreadWorld, requestId: string, command: string) => {
  const { items } = hostState(ctx, "approvals");
  expect(items.filter((item: { active: boolean }) => item.active).map((item: { requestId: string }) => item.requestId)).toEqual([requestId]);
  expect(await snapshot(ctx)).toContain(`▸ command: ${command}`);
};

step("the first one is highlighted", (ctx: ThreadWorld) => expectHighlighted(ctx, "r1", "rm -rf build"));
step("the second approval is highlighted", (ctx: ThreadWorld) => expectHighlighted(ctx, "r2", "git push"));

// The prompt belongs to the composer port; with no composer published the prompt is empty.
step("the prompt is empty", (ctx: ThreadWorld) => {
  expect(hostState(ctx, "composer")?.text ?? "").toBe("");
});

step("{string} approves that one", async (ctx: ThreadWorld, chord: string) => {
  await pressKey(ctx, chord);
  await settle();
  expect(recorded(ctx, "approve")).toEqual([["t1", "r2", "accept"]]);
});

step("the prompt contains two lines of text", async (ctx: ThreadWorld) => {
  ctx.host!.dispatch("composer.text.set", { text: "first line\nsecond line" });
  await settle();
  if (hostState(ctx, "composer")?.text !== "first line\nsecond line") {
    throw new Error("needs the prompt from the composer port (Shell.state.composer, composer.text.set)");
  }
});

step(
  "the cursor moves up a line and the highlighted approval does not change",
  async (ctx: ThreadWorld) => {
    await settle();
    expect(hostState(ctx, "approvals").index).toBe(0);
    expect(hostState(ctx, "composer").text).toBe("first line\nsecond line");
    await expectHighlighted(ctx, "r1", "rm -rf build");
  },
);

step("another client approves it", async (ctx: ThreadWorld) => {
  await updateThread(ctx, (detail) => ({
    activities: [...detail.activities, approvalResolved("r1", 5)],
  }));
});

step("the request is no longer pending in the terminal client", async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "approvals").count).toBe(0);
  expect(findObject(ctx, "approvals").get("visible")).toBe(false);
  const screen = await snapshot(ctx);
  expect(screen).not.toContain("rm -rf build");
  expect(screen).not.toContain("^A/^R approve");
});

// --- questions ----------------------------------------------------------------------

async function ask(ctx: ThreadWorld, questions: ReadonlyArray<QuestionFixture>) {
  if (!ctx.app) await openThread(ctx);
  await updateThread(ctx, () => ({
    ...RUNNING(),
    activities: [questionRequest("req-1", questions, 1)],
  }));
}

const DATABASE = (multiSelect = false): QuestionFixture => ({
  id: "q1",
  header: "Database",
  question: "Which database?",
  options: ["Postgres", "SQLite"],
  multiSelect,
});

step(
  /^the agent (?:asks|has asked) "([^"]*)" with (?:the )?options "([^"]*)" and "([^"]*)"$/,
  async (ctx: ThreadWorld, question: string, first: string, second: string) => {
    await ask(ctx, [{ ...DATABASE(), question, options: [first, second] }]);
  },
);

step(
  "the agent asks {string} allowing several of {string}, {string} and {string}",
  async (ctx: ThreadWorld, question: string, ...options: string[]) => {
    await ask(ctx, [{ id: "q1", header: "Checks", question, options, multiSelect: true }]);
  },
);

step("a question is pending", (ctx: ThreadWorld) => ask(ctx, [DATABASE()]));
step("a multiple-choice question with nothing selected", (ctx: ThreadWorld) =>
  ask(ctx, [DATABASE(true)]),
);

step("the agent asks two questions in one request", (ctx: ThreadWorld) =>
  ask(ctx, [
    DATABASE(),
    { id: "q2", header: "Cache", question: "Which cache?", options: ["Redis", "None"] },
  ]),
);

step("a question with thirty options", (ctx: ThreadWorld) =>
  ask(ctx, [
    {
      id: "q1",
      question: "Which option?",
      options: Array.from({ length: 30 }, (_, index) => `Option ${index + 1}`),
    },
  ]),
);

step("the question allows several answers", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({ activities: [questionRequest("req-1", [DATABASE(true)], 1)] }));
});

/** Move the highlight to `label` with the arrow keys. */
async function moveTo(ctx: ThreadWorld, label: string) {
  for (let presses = 0; presses < 40; presses += 1) {
    const current = hostState(ctx, "userInput").options.find(
      (option: { highlighted: boolean }) => option.highlighted,
    );
    if (current?.label === label) return;
    await pressKey(ctx, "Down");
  }
  throw new Error(`the arrow keys never reached "${label}"`);
}

async function pick(ctx: ThreadWorld, labels: ReadonlyArray<string>) {
  for (const label of labels) {
    await moveTo(ctx, label);
    if (hostState(ctx, "userInput").multiSelect) await pressKey(ctx, "Space");
  }
}

step("the user moves to {string} and presses {string}", async (ctx: ThreadWorld, label: string, key: string) => {
  await moveTo(ctx, label);
  await pressKey(ctx, key);
  await settle();
});

step(
  "the user toggles {string} and {string} with {string} and presses {string}",
  async (ctx: ThreadWorld, first: string, second: string, toggle: string, submit: string) => {
    for (const label of [first, second]) {
      await moveTo(ctx, label);
      await pressKey(ctx, toggle);
    }
    await pressKey(ctx, submit);
    await settle();
  },
);

step("the user picks {string} and submits", async (ctx: ThreadWorld, label: string) => {
  await pick(ctx, [label]);
  await pressKey(ctx, "Enter");
  await settle();
});

step("the user picks {string} and {string} and submits", async (ctx: ThreadWorld, first: string, second: string) => {
  await pick(ctx, [first, second]);
  await pressKey(ctx, "Enter");
  await settle();
});

step("the user picked {string}", (ctx: ThreadWorld, label: string) => pick(ctx, [label]));

step("the user types {string} and submits", async (ctx: AnswerWorld, text: string) => {
  await typeText(ctx, text);
  await pressKey(ctx, "Enter");
  await settle();
});

step("the user types {string} and presses {string}", async (ctx: AnswerWorld, text: string, key: string) => {
  await typeText(ctx, text);
  await pressKey(ctx, key);
  await settle();
});

step("the user types {string} as a custom answer", async (ctx: AnswerWorld, text: string) => {
  ctx.typedAnswer = text;
  await typeText(ctx, text);
});

step("the user typed a custom answer", async (ctx: AnswerWorld) => {
  await ask(ctx, [DATABASE()]);
  ctx.typedAnswer = "MySQL";
  await typeText(ctx, "MySQL");
});

step("the user submits without picking or typing anything", async (ctx: ThreadWorld) => {
  await updateThread(ctx, () => ({ activities: [questionRequest("req-1", [DATABASE(true)], 1)] }));
  await pressKey(ctx, "Enter");
  await settle();
});

const expectAnswer = (ctx: ThreadWorld, answers: Record<string, unknown>) => {
  expect(recorded(ctx, "respondUserInput")).toEqual([["t1", "req-1", answers]]);
};

step("the answer {string} is sent", async (ctx: ThreadWorld, answer: string) => {
  await settle();
  expectAnswer(ctx, { q1: answer });
});

step("the agent receives {string} as the answer", async (ctx: ThreadWorld, answer: string) => {
  await settle();
  expectAnswer(ctx, { q1: answer });
});

step("the answer is {string} and {string}", async (ctx: ThreadWorld, first: string, second: string) => {
  await settle();
  expectAnswer(ctx, { q1: [first, second] });
});

step("the agent receives both answers", async (ctx: ThreadWorld) => {
  await settle();
  expectAnswer(ctx, { q1: ["Postgres", "SQLite"] });
});

step("the user is told the answer was sent", async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "status")).toEqual({ kind: "success", text: "Answer sent." });
  expect(await snapshot(ctx)).toContain("Answer sent.");
});

step("the user is asked to pick an option or type an answer first", async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "status").text).toBe("Pick an option or type an answer first.");
  expect(await snapshot(ctx)).toContain("Pick an option or type an answer first.");
});

step("nothing is sent", (ctx: ThreadWorld) => {
  expect(recorded(ctx, "respondUserInput")).toEqual([]);
});

step("the composer shows the question with its options", async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "mode")).toBe("userInput");
  const screen = await snapshot(ctx);
  expect(screen).toContain("Which database?");
  expect(screen).toContain("▸ ( ) Postgres");
  expect(screen).toContain("  ( ) SQLite");
});

step("the primary action is {string}", async (ctx: ThreadWorld, label: string) => {
  expect(await snapshot(ctx)).toContain(`[ ${label} ]`);
});

step("the custom answer keeps its spaces", async (ctx: AnswerWorld) => {
  expect(hostState(ctx, "userInput").customAnswer).toBe(ctx.typedAnswer);
  expect(await snapshot(ctx)).toContain(ctx.typedAnswer!);
});

step("no option is toggled", (ctx: ThreadWorld) => {
  const { options } = hostState(ctx, "userInput");
  expect(options.some((option: { selected: boolean }) => option.selected)).toBe(false);
});

step("the user answers the first", async (ctx: ThreadWorld) => {
  await pressKey(ctx, "Enter");
  await settle();
});

step("the second question is shown", async (ctx: ThreadWorld) => {
  expect(recorded(ctx, "respondUserInput")).toEqual([]);
  const screen = await snapshot(ctx);
  expect(screen).toContain("Which cache?");
  expect(screen).toContain("(2 of 2)");
  expect(screen).toContain("▸ ( ) Redis");
});

step("the answers are sent together after the last one", async (ctx: ThreadWorld) => {
  await pressKey(ctx, "Enter");
  await settle();
  expectAnswer(ctx, { q1: "Postgres", q2: "Redis" });
});

step(
  "the user presses {string} twice and the request fails",
  async (ctx: AnswerWorld, key: string) => {
    const reply = deferred();
    ctx.respond!.respondUserInput = () => reply.promise;
    await pressKey(ctx, key);
    await pressKey(ctx, key);
    reply.reject(new Error("connection dropped"));
    await settle();
  },
);

step("one answer was sent", (ctx: ThreadWorld) => {
  expect(recorded(ctx, "respondUserInput")).toHaveLength(1);
});

step("the custom answer is still in the composer", async (ctx: AnswerWorld) => {
  expect(hostState(ctx, "userInput")).toMatchObject({ active: true, customAnswer: ctx.typedAnswer });
  expect(findObject(ctx, "userInputAnswer").get("text")).toBe(ctx.typedAnswer);
  expect(await snapshot(ctx)).toContain("answer failed: connection dropped");
});

const expectQuestionClosed = async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "mode")).toBe("compose");
  expect(findObject(ctx, "pendingUserInput").get("visible")).toBe(false);
  const screen = await snapshot(ctx);
  expect(screen).not.toContain("[ Submit answer ]");
  expect(screen).toContain("⚠ question pending — ^U to answer");
};

step(
  "the question panel closes and the user can write a normal reply",
  expectQuestionClosed,
);

step("the user set a pending question aside", async (ctx: ThreadWorld) => {
  await ask(ctx, [DATABASE()]);
  await pressKey(ctx, "Esc");
});

step("the user puts the question off", (ctx: ThreadWorld) => pressKey(ctx, "Esc"));
step("the user can write a normal message", expectQuestionClosed);
step("the user reopens the pending question", (ctx: ThreadWorld) => pressKey(ctx, "Ctrl+U"));

const expectQuestionOpen = async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "mode")).toBe("userInput");
  expect(findObject(ctx, "pendingUserInput").get("visible")).toBe(true);
  expect(await snapshot(ctx)).toContain("[ Submit answer ]");
};

step("the question panel opens again", expectQuestionOpen);

step("{string} is shown again with its options", async (ctx: ThreadWorld, question: string) => {
  await expectQuestionOpen(ctx);
  const screen = await snapshot(ctx);
  expect(screen).toContain(question);
  expect(screen).toContain("( ) Postgres");
  expect(screen).toContain("( ) SQLite");
});

step("the user moves down to the twentieth option", async (ctx: ThreadWorld) => {
  for (let presses = 0; presses < 19; presses += 1) await pressKey(ctx, "Down");
});

step("the twentieth option is visible and highlighted", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("▸ ( ) Option 20");
  expect(screen).not.toContain("( ) Option 1\n");
});

// --- plans ----------------------------------------------------------------------------

const planMarkdown = (title: string) =>
  [`# ${title}`, "", "## Summary", "", "Cache the product list.", "", "- Add a cache layer", "- Invalidate on write"].join("\n");

async function proposePlan(ctx: ThreadWorld, extra: Parameters<typeof plan>[3] = {}) {
  await updateThread(ctx, () => ({ proposedPlans: [plan("plan-1", planMarkdown("Add caching"), 5, extra)] }));
}

step("the agent proposed a plan titled {string}", async (ctx: ThreadWorld, title: string) => {
  await updateThread(ctx, () => ({ proposedPlans: [plan("plan-1", planMarkdown(title), 5)] }));
});

step("the agent proposed a plan", (ctx: ThreadWorld) => proposePlan(ctx));

step("the agent proposed a plan and the thread is idle", async (ctx: ThreadWorld) => {
  // The turn that asked has finished, so its question is resolved.
  await updateThread(ctx, (detail) => ({
    session: { status: "idle" } as never,
    latestTurn: latestTurn("turn-1", 0, 30),
    activities: [
      ...detail.activities,
      activity("act-req-1-resolved", 30, {
        tone: "info",
        kind: "user-input.resolved",
        summary: "User input resolved",
        payload: { requestId: "req-1" },
      }),
    ],
    proposedPlans: [plan("plan-1", planMarkdown("Add caching"), 5, { turnId: "turn-1" } as never)],
  }));
  expect(hostState(ctx, "mode")).toBe("compose");
  expect(plain(hostState(ctx, "timeline").header.right.text)).toStartWith("idle");
});

step("the timeline shows a plan card titled {string}", async (ctx: ThreadWorld, title: string) => {
  expect(findObject(ctx, "planCard").get("visible")).toBe(true);
  expect(plain(hostState(ctx, "timeline").plan.title)).toBe(`◆ ${title}`);
  expect(await snapshot(ctx)).toContain(`◆ ${title}`);
});

step(
  "the plan body does not repeat the title or a {string} heading",
  async (ctx: ThreadWorld, heading: string) => {
    const body = hostState(ctx, "timeline").plan.lines.map(plain).join("\n");
    expect(body).toContain("Cache the product list.");
    expect(body).not.toContain("Add caching");
    expect(body).not.toContain(heading);
    const screen = await snapshot(ctx);
    expect(screen.split("Add caching")).toHaveLength(2);
    expect(screen).not.toContain(heading);
  },
);

step("the plan is handed to the agent to implement", async (ctx: ThreadWorld) => {
  await settle();
  const calls = recorded(ctx, "implementPlan") as Array<[{ id: string }, string]>;
  expect(calls.map(([detail, planId]) => [detail.id, planId])).toEqual([["t1", "plan-1"]]);
});

step("the user chooses to implement the plan", async (ctx: ThreadWorld) => {
  await pressKey(ctx, "Ctrl+Y");
  await settle();
});

step("a turn starts that carries out the plan", async (ctx: ThreadWorld) => {
  const calls = recorded(ctx, "implementPlan") as Array<[{ id: string }, string]>;
  expect(calls.map(([detail, planId]) => [detail.id, planId])).toEqual([["t1", "plan-1"]]);
  expect(await snapshot(ctx)).toContain("Implementing plan…");
});

step("the latest plan was already implemented", (ctx: ThreadWorld) =>
  proposePlan(ctx, { implementedAt: new Date().toISOString(), implementationThreadId: "t9" } as never),
);

step("no plan card is shown", async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "timeline").plan).toBeNull();
  expect(findObject(ctx, "planCard").get("visible")).toBe(false);
  expect(await snapshot(ctx)).not.toContain("Add caching");
});

step(
  "the latest turn proposed a plan and an older turn's plan was edited later",
  async (ctx: ThreadWorld) => {
    await updateThread(ctx, () => ({
      latestTurn: latestTurn("turn-2", 10, 20),
      proposedPlans: [
        plan("latest", "# Latest turn plan\n\nShip it.", 20, { turnId: "turn-2" } as never),
        plan("older", "# Older turn plan\n\nWait.", 40, { turnId: "turn-1" } as never),
      ],
    }));
  },
);

step("the plan card shows the latest turn's plan", async (ctx: ThreadWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("◆ Latest turn plan");
  expect(screen).not.toContain("Older turn plan");
});

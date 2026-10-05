// features/timeline/approvals-and-questions.feature on the terminal client:
// the four answers to an approval, what a request says about itself, and the
// agent's questions. The fake MC resolves a request once it is answered.
import { expect } from "bun:test";

import { PROVIDER_GONE } from "../../../src/approvals.ts";
import { step } from "../../steps.ts";
import { findObject, pressKey, snapshot, typeText } from "../world.ts";
import {
  approvalResolved,
  hostState,
  latestTurn,
  questionRequest,
  recorded,
  settle,
  shownText,
  updateThread,
  type ThreadWorld,
} from "../threadWorld.ts";
import { addItem, settleRun, startRun, turns, type TurnWorld } from "../turnWorld.ts";

// --- answering an approval -------------------------------------------------------------

const DECISIONS: Record<string, { key: string; decision: string; status: string }> = {
  "approve it": { key: "Ctrl+A", decision: "accept", status: "Approved." },
  "decline it": { key: "Ctrl+R", decision: "decline", status: "Declined." },
  "always allow it this session": {
    key: "Ctrl+S",
    decision: "acceptForSession",
    status: "Approved for this session.",
  },
  "cancel the request": { key: "Ctrl+X", decision: "cancel", status: "Request cancelled." },
};

step(
  /^the user chooses to (approve it|decline it|always allow it this session|cancel the request)$/,
  async (ctx: ThreadWorld, choice: string) => {
    // The MC passes the answer to the provider and closes the request.
    ctx.respond!.approve = async (_thread, requestId) => {
      await updateThread(ctx, (detail) => ({
        activities: [...detail.activities, approvalResolved(requestId, 5)],
      }));
    };
    await pressKey(ctx, DECISIONS[choice]!.key);
    await settle();
  },
);

async function expectAnswered(ctx: ThreadWorld, choice: string) {
  const { decision, status } = DECISIONS[choice]!;
  expect(recorded(ctx, "approve")).toEqual([["t1", "r1", decision]]);
  expect(hostState(ctx, "status")).toEqual({ kind: "success", text: status });
  // The request is answered: nothing is left to approve.
  expect(hostState(ctx, "approvals").count).toBe(0);
  expect(findObject(ctx, "approvals").get("visible")).toBe(false);
  expect(await snapshot(ctx)).not.toContain("Approval required");
}

const expectStillWorking = async (ctx: ThreadWorld) => {
  expect(hostState(ctx, "timeline").working).not.toBeNull();
  expect(await snapshot(ctx)).toContain("● Working…");
};

step("the command runs and the agent continues", async (ctx: ThreadWorld) => {
  await expectAnswered(ctx, "approve it");
  await expectStillWorking(ctx);
});

step("the command is not run and the agent is told it was declined", async (ctx: ThreadWorld) => {
  await expectAnswered(ctx, "decline it");
  await expectStillWorking(ctx);
});

step(
  "the command runs and matching requests stop asking this session",
  async (ctx: ThreadWorld) => {
    await expectAnswered(ctx, "always allow it this session");
    await expectStillWorking(ctx);
  },
);

step("the command is not run and the turn stops waiting", async (ctx: ThreadWorld) => {
  await expectAnswered(ctx, "cancel the request");
});

// --- what a request says about itself --------------------------------------------------

const REQUEST_KINDS: Record<string, string> = {
  "to run a command": "command",
  "to read a file": "file-read",
  "to change a file": "file-change",
  "access for an app": "mcp-elicitation",
  "a permission for an app": "permission",
};

async function requestApproval(
  ctx: TurnWorld,
  requestKind: string,
  prompt: string,
  fields: Record<string, unknown> = {},
) {
  await startRun(ctx);
  await addItem(ctx, "approval_request", {
    requestId: "request-1",
    requestKind,
    prompt,
    ...fields,
  });
}

step(
  new RegExp(`^the agent requests (${Object.keys(REQUEST_KINDS).join("|")})$`),
  async (ctx: TurnWorld, kind: string) => {
    await requestApproval(ctx, REQUEST_KINDS[kind]!, "Allow this?");
  },
);

step("the request is titled {string}", async (ctx: TurnWorld, title: string) => {
  expect(hostState(ctx, "approvals").title).toBe(title);
  expect(shownText(findObject(ctx, "approvalTitle").get("text"))).toBe(title);
  expect(await snapshot(ctx)).toContain(title);
});

const WARNING = "The app may follow instructions injected into pages it reads.";

step(
  "the provider warns that an option may follow injected instructions",
  async (ctx: TurnWorld) => {
    await requestApproval(ctx, "mcp-elicitation", "Allow the browser app?", {
      options: [
        { decision: "accept", label: "Allow" },
        { decision: "acceptForSession", label: "Always allow", warning: WARNING },
        { decision: "decline", label: "Deny" },
      ],
    });
  },
);

step("the user reviews the approval", async (ctx: TurnWorld) => {
  expect(findObject(ctx, "approvals").get("visible")).toBe(true);
  expect(await snapshot(ctx)).toContain("^A Allow · ^S Always allow · ^R Deny");
});

step("the warning is shown next to that option", async (ctx: TurnWorld) => {
  const { options, warnings } = hostState(ctx, "approvals");
  expect(
    options
      .filter((option: { warning: string }) => option.warning !== "")
      .map((option: { label: string }) => option.label),
  ).toEqual(["Always allow"]);
  expect(warnings).toEqual([
    { decision: "acceptForSession", text: `⚠ ^S Always allow: ${WARNING}` },
  ]);
  // On screen the warning starts on the line that names the option.
  const row = (await snapshot(ctx)).split("\n").find((line) => line.includes("⚠ ^S Always allow:"));
  expect(row).toContain("The app may follow");
});

// --- several approvals -----------------------------------------------------------------

step("the user sees {string}", async (ctx: ThreadWorld, text: string) => {
  expect(hostState(ctx, "approvals").countText).toBe(text);
  expect(await snapshot(ctx)).toContain(`Approval required  ${text}`);
});

step("the user moves to the next approval", async (ctx: ThreadWorld) => {
  await pressKey(ctx, "Down");
});

step("the user moves back", async (ctx: ThreadWorld) => {
  await pressKey(ctx, "Up");
});

// --- a request whose agent is gone -----------------------------------------------------

step("the provider process stopped while an approval was pending", async (ctx: TurnWorld) => {
  (await turns(ctx)).requests.push({
    id: "request-1",
    kind: "command",
    status: "pending",
    responseCapability: { type: "not_resumable", reason: "provider process exited" },
  });
  await requestApproval(ctx, "command", "rm -rf dist");
});

step("the approval cannot be answered", async (ctx: TurnWorld) => {
  expect(hostState(ctx, "approvals")).toMatchObject({ count: 1, canRespond: false });
  for (const key of ["Ctrl+A", "Ctrl+S", "Ctrl+R", "Ctrl+X"]) await pressKey(ctx, key);
  await settle();
  expect(recorded(ctx, "approve")).toEqual([]);
  expect(hostState(ctx, "approvals").count).toBe(1);
  // The panel says why in place of the keys that would answer.
  expect(findObject(ctx, "approvalHint").get("visible")).toBe(false);
  expect(shownText(findObject(ctx, "approvalProblem").get("text"))).toBe(PROVIDER_GONE);
  expect(await snapshot(ctx)).toContain("Provider process is gone");
});

// --- the agent's questions -------------------------------------------------------------

async function askDatabase(ctx: ThreadWorld, question: string, options: string[]) {
  await updateThread(ctx, () => ({
    session: { status: "running" } as never,
    latestTurn: latestTurn("turn-1", 0),
    activities: [
      questionRequest("req-1", [{ id: "q1", header: "Question", question, options }], 1),
    ],
  }));
  expect(await snapshot(ctx)).toContain(question);
}

step(
  "the agent asks {string} with the options {string}, {string} and {string}",
  (ctx: ThreadWorld, question: string, ...options: string[]) => askDatabase(ctx, question, options),
);

step("the agent asks {string} with three options", (ctx: ThreadWorld, question: string) =>
  askDatabase(ctx, question, ["Postgres", "SQLite", "MySQL"]),
);

step("the question allows one answer", (ctx: ThreadWorld) => {
  expect(hostState(ctx, "userInput")).toMatchObject({ active: true, multiSelect: false });
});

/** Move the highlight to `label` with the arrow keys. */
async function moveTo(ctx: ThreadWorld, label: string) {
  for (let presses = 0; presses < 10; presses += 1) {
    const current = hostState(ctx, "userInput").options.find(
      (option: { highlighted: boolean }) => option.highlighted,
    );
    if (current?.label === label) return;
    await pressKey(ctx, "Down");
  }
  throw new Error(`the arrow keys never reached "${label}"`);
}

step("the user picks {string}", async (ctx: ThreadWorld, label: string) => {
  await moveTo(ctx, label);
  await pressKey(ctx, "Enter");
  await settle();
});

step(
  "the user picks {string} and {string}",
  async (ctx: ThreadWorld, first: string, second: string) => {
    expect(hostState(ctx, "userInput").multiSelect).toBe(true);
    for (const label of [first, second]) {
      await moveTo(ctx, label);
      await pressKey(ctx, "Space");
    }
    await pressKey(ctx, "Enter");
    await settle();
  },
);

step("the user answers {string}", async (ctx: ThreadWorld, answer: string) => {
  await typeText(ctx, answer);
  await pressKey(ctx, "Enter");
  await settle();
});

step("the agent receives {string}", async (ctx: ThreadWorld, answer: string) => {
  expect(recorded(ctx, "respondUserInput")).toEqual([["t1", "req-1", { q1: answer }]]);
  expect(hostState(ctx, "status")).toEqual({ kind: "success", text: "Answer sent." });
});

step(
  "the agent receives {string} and {string}",
  async (ctx: ThreadWorld, first: string, second: string) => {
    expect(recorded(ctx, "respondUserInput")).toEqual([["t1", "req-1", { q1: [first, second] }]]);
    expect(hostState(ctx, "status")).toEqual({ kind: "success", text: "Answer sent." });
  },
);

// A question the provider takes as an ordinary message outlives the turn that asked it.
step("the agent asked a question that can be answered by message", async (ctx: TurnWorld) => {
  await startRun(ctx, 30);
  (await turns(ctx)).requests.push({
    id: "request-q",
    kind: "user_input",
    status: "pending",
    responseCapability: { type: "message" },
  });
  await addItem(ctx, "user_input_request", {
    requestId: "request-q",
    responseMode: "message",
    status: "waiting",
    questions: [
      {
        id: "q1",
        header: "Database",
        question: "Which database?",
        options: ["Postgres", "SQLite"].map((label) => ({ label, description: label })),
      },
    ],
  });
});

step("the turn ends before the user answers", async (ctx: TurnWorld) => {
  await settleRun(ctx, "completed", 30);
  expect(ctx.thread!.latestTurn!.state).toBe("completed");
  expect(hostState(ctx, "timeline").working).toBeNull();
});

step("the user can still answer the question", async (ctx: TurnWorld) => {
  expect(hostState(ctx, "mode")).toBe("userInput");
  expect(findObject(ctx, "pendingUserInput").get("visible")).toBe(true);
  expect(await snapshot(ctx)).toContain("Which database?");
  await moveTo(ctx, "SQLite");
  await pressKey(ctx, "Enter");
  await settle();
  expect(recorded(ctx, "respondUserInput")).toEqual([["t1", "request-q", { q1: "SQLite" }]]);
});

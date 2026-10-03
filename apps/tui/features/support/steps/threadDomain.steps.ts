// The TUI's steps for the shared thread domain files (features/timeline/*):
// failed approval answers and reverting to a checkpoint.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { chooseCommand } from "../threadUi.ts";
import { findObject, pressKey, snapshot } from "../world.ts";
import {
  activity,
  approvalRequest,
  checkpoint,
  deferred,
  hostState,
  latestTurn,
  message,
  openThread,
  recorded,
  settle,
  updateThread,
  type ThreadWorld,
} from "../threadWorld.ts";

interface DomainWorld extends ThreadWorld {
  approveReply?: ReturnType<typeof deferred<void>>;
}

step(
  "the user is looking at a thread in {string} whose agent is working",
  async (ctx: DomainWorld, projectTitle: string) => {
    ctx.projectTitle = projectTitle;
    await openThread(ctx);
    await updateThread(ctx, () => ({
      session: { status: "running" } as never,
      latestTurn: latestTurn("turn-1", 0),
    }));
    expect(hostState(ctx, "page").projectTitle).toBe(projectTitle);
  },
);

// --- a failed approval answer ------------------------------------------------------

step("the user approved a pending request", async (ctx: DomainWorld) => {
  await updateThread(ctx, (detail) => ({
    activities: [...detail.activities, approvalRequest("r1", "rm -rf build", 1)],
  }));
  const reply = deferred();
  ctx.approveReply = reply;
  ctx.respond!.approve = () => reply.promise;
  await pressKey(ctx, "Ctrl+A");
  expect(recorded(ctx, "approve")).toEqual([["t1", "r1", "accept"]]);
});

const FAILURE_DETAILS: Record<string, string> = {
  "the request was already resolved": "Unknown pending approval request: r1",
  "the connection dropped for a moment": "connection reset by peer",
};

step(
  /^sending the answer fails because (the request was already resolved|the connection dropped for a moment)$/,
  async (ctx: DomainWorld, reason: string) => {
    const detail = FAILURE_DETAILS[reason]!;
    ctx.approveReply!.reject(new Error(detail));
    await updateThread(ctx, (thread) => ({
      activities: [
        ...thread.activities,
        activity("act-r1-failed", 2, {
          tone: "error",
          kind: "provider.approval.respond.failed",
          summary: "Approval response failed",
          payload: { requestId: "r1", detail },
        }),
      ],
    }));
  },
);

step("the approval is closed", async (ctx: DomainWorld) => {
  expect(hostState(ctx, "approvals").count).toBe(0);
  expect(findObject(ctx, "approvals").get("visible")).toBe(false);
  expect(await snapshot(ctx)).not.toContain("Approval required");
});

step("the approval is still open so the user can answer again", async (ctx: DomainWorld) => {
  expect(hostState(ctx, "approvals").count).toBe(1);
  expect(await snapshot(ctx)).toContain("▸ command: rm -rf build");
  ctx.respond!.approve = async () => {};
  await pressKey(ctx, "Ctrl+A");
  await settle();
  expect(recorded(ctx, "approve")).toEqual([
    ["t1", "r1", "accept"],
    ["t1", "r1", "accept"],
  ]);
  expect(hostState(ctx, "status").text).toBe("Approved.");
});

// --- reverting to a checkpoint --------------------------------------------------------

const turnMessages = (turn: number) => [
  message(`u${turn}`, "user", `Request ${turn}`, turn * 100, { turnId: `turn-${turn}` } as never),
  message(`a${turn}`, "assistant", `Answer ${turn}`, turn * 100 + 50, {
    turnId: `turn-${turn}`,
  } as never),
];

step(
  "a thread in {string} with three finished turns",
  async (ctx: DomainWorld, projectTitle: string) => {
    ctx.projectTitle = projectTitle;
    await openThread(ctx);
    await updateThread(ctx, () => ({
      latestTurn: latestTurn("turn-3", 300, 350, "a3"),
      messages: [1, 2, 3].flatMap(turnMessages),
      checkpoints: [1, 2, 3].map((turn) =>
        checkpoint(turn, [`src/turn${turn}.ts`], turn * 100 + 50, `a${turn}`),
      ),
    }));
  },
);

step("the user reverts the thread to the checkpoint after turn 1", async (ctx: DomainWorld) => {
  // The server restores the workspace and drops the later turns from the thread.
  ctx.respond!.revertCheckpoint = async () => {
    await updateThread(ctx, (detail) => ({
      latestTurn: latestTurn("turn-1", 100, 150, "a1"),
      messages: turnMessages(1),
      checkpoints: detail.checkpoints.filter((entry) => entry.checkpointTurnCount <= 1),
    }));
  };
  ctx.host!.dispatch("checkpoint.revert.open");
  await pressKey(ctx, "Down");
  await pressKey(ctx, "Down");
  expect(await snapshot(ctx)).toContain("▸ turn 1 · 1 file");
  // Enter picks the checkpoint, and again to confirm the rollback.
  await pressKey(ctx, "Enter");
  await pressKey(ctx, "Enter");
  await settle();
});

// --- rolling back asks first ----------------------------------------------------------

step("the user rolls back to a checkpoint", async (ctx: DomainWorld) => {
  await chooseCommand(ctx, "Revert to checkpoint…");
  expect(findObject(ctx, "revertPicker").get("visible")).toBe(true);
  await pressKey(ctx, "Enter");
  await settle();
});

step(
  "the user is asked to confirm that the rollback cannot be undone",
  async (ctx: DomainWorld) => {
    // The newest checkpoint is the one picked; nothing was sent yet.
    expect(hostState(ctx, "revert")).toMatchObject({ open: true, confirming: 3 });
    expect(recorded(ctx, "revertCheckpoint")).toEqual([]);
    const screen = await snapshot(ctx);
    expect(screen).toContain("roll back to turn 3? This cannot be undone.");
    expect(screen).toContain("Enter roll back · Esc cancel");
    // Esc answers no: the thread stays as it was.
    await pressKey(ctx, "Esc");
    await settle();
    expect(findObject(ctx, "revertPicker").get("visible")).toBe(false);
    expect(recorded(ctx, "revertCheckpoint")).toEqual([]);
    expect(await snapshot(ctx)).toContain("Answer 3");
  },
);

step("turns 2 and 3 are removed from the conversation", async (ctx: DomainWorld) => {
  const screen = await snapshot(ctx);
  expect(screen).toContain("Request 1");
  expect(screen).toContain("Answer 1");
  for (const gone of ["Request 2", "Answer 2", "Request 3", "Answer 3"]) {
    expect(screen).not.toContain(gone);
  }
});

step("the workspace files match the end of turn 1", (ctx: DomainWorld) => {
  expect(recorded(ctx, "revertCheckpoint")).toEqual([["t1", 1]]);
});

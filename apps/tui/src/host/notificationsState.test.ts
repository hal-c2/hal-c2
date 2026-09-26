import { describe, expect, it } from "bun:test";

import type { OrchestrationShellSnapshot } from "../connection.ts";
import { nextThreadAlerts, threadTransitions } from "./notificationsState.ts";

type ShellThread = OrchestrationShellSnapshot["threads"][number];

const thread = (id: string, extra: Record<string, unknown> = {}): ShellThread =>
  ({
    id,
    title: `Thread ${id}`,
    latestTurn: { turnId: "turn-1", state: "running" },
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    archivedAt: null,
    ...extra,
  }) as unknown as ShellThread;

const done = (id: string) => thread(id, { latestTurn: { turnId: "turn-1", state: "completed" } });

let ids = 0;
const nextId = () => `n${++ids}`;

describe("thread alerts", () => {
  it("raise nothing for the state threads were in when the client connected", () => {
    expect(threadTransitions(null, [done("a")])).toEqual([]);
  });

  it("raise one alert per transition, except for the thread being viewed", () => {
    const before = [thread("a"), thread("b"), thread("c")];
    const after = [done("a"), thread("b", { hasPendingApprovals: true }), done("c")];
    const alerts = nextThreadAlerts([], threadTransitions(before, after), "c", nextId);
    expect(alerts.map((alert) => [alert.threadId, alert.title])).toEqual([
      ["b", "Approval needed"],
      ["a", "Thread completed"],
    ]);
    expect(alerts[0]!.actions).toEqual([{ id: "open", label: "Open", primary: true }]);
  });

  it("keep the newest alert per thread and at most three", () => {
    const failed = thread("a", { latestTurn: { turnId: "turn-2", state: "error" } });
    let alerts = nextThreadAlerts([], threadTransitions([thread("a")], [done("a")]), null, nextId);
    alerts = nextThreadAlerts(alerts, threadTransitions([done("a")], [failed]), null, nextId);
    expect(alerts.map((alert) => alert.title)).toEqual(["Thread failed"]);

    const many = ["b", "c", "d", "e"];
    alerts = nextThreadAlerts(alerts, threadTransitions(many.map((id) => thread(id)), many.map(done)), null, nextId);
    expect(alerts.map((alert) => alert.threadId)).toEqual(["e", "d", "c"]);
  });
});

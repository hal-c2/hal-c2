import { describe, expect, it } from "bun:test";
import type { TerminalAttachStreamEvent } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";
import { fakeClient } from "../../features/support/fakeClient.ts";
import { createHost } from "./host.ts";
import { terminalNumber, type TuiTerminalState } from "./terminalState.ts";

function boot(rows = 40) {
  const fake = fakeClient();
  const host = createHost({ client: fake.client, size: { columns: 140, rows }, log: () => {} });
  fake.connect();
  host.dispatch("thread.open", { key: "local:t1" });
  const terminal = () => host.state.get("terminal") as any;
  // The palette lists the terminal entries among the rest.
  const titles = () => {
    host.dispatch("palette.open");
    const items = (host.state.get("palette") as { commands: Array<{ title: string }> }).commands;
    host.dispatch("palette.close");
    return items.map((item) => item.title);
  };
  return { ...fake, host, terminal, titles };
}

describe("terminalNumber", () => {
  it("reads N from term-N and falls back to the position otherwise", () => {
    expect(terminalNumber("term-4", 0)).toBe(4);
    expect(terminalNumber("custom", 2)).toBe(3);
  });
});

describe("acknowledging terminal output", () => {
  const running = (sequence: number, history = "") => ({
    type: "snapshot" as const,
    snapshot: { status: "running", pid: 1, history, sequence },
  });
  const output = (sequence: number, data: string) => ({
    type: "output" as const,
    data,
    sequence,
  });

  /** A drawer on a client that records acks and hands the test its event stream. */
  function attached() {
    const fake = fakeClient();
    const acks: number[] = [];
    let nextAck = () => {};
    let emit = (_event: unknown) => {};
    const client: TuiClient = {
      ...fake.client,
      subscribeTerminal: (_input, onEvent) => {
        emit = (event) =>
          onEvent(event as TerminalAttachStreamEvent, (sequence) => {
            acks.push(sequence);
            nextAck();
          });
        return () => {};
      },
    };
    const host = createHost({ client, size: { columns: 140, rows: 40 }, log: () => {} });
    fake.connect();
    host.dispatch("thread.open", { key: "local:t1" });
    host.dispatch("terminal.toggle");
    const screen = () =>
      (host.state.get("terminal") as TuiTerminalState).lines
        .map((line) => line.chunks.map((part) => part.text).join(""))
        .join("\n");
    const nextAcked = () => new Promise<void>((resolve) => (nextAck = resolve));
    return { host, acks, emit: (event: unknown) => emit(event), screen, nextAcked };
  }

  it("acknowledges a snapshot once the emulator has it", async () => {
    const { host, acks, emit } = attached();
    await host.settled();
    emit(running(3, "history"));
    expect(acks).toEqual([]);
    await host.settled();
    expect(acks).toEqual([3]);
  });

  it("acknowledges a burst by its newest sequence once enough of it is handled", async () => {
    const { host, acks, emit } = attached();
    emit(running(0));
    await host.settled();
    emit(output(1, "x".repeat(10 * 1024)));
    emit(output(2, "x".repeat(10 * 1024)));
    emit(output(3, "x".repeat(10 * 1024)));
    await host.settled();
    // Not one ack per event: the first two together make enough, the last waits a moment.
    expect(acks).toEqual([0, 2]);
  });

  it("acknowledges the last of the output even when no more comes", async () => {
    const { host, acks, emit, nextAcked } = attached();
    emit(running(0));
    await host.settled();
    const acked = nextAcked();
    emit(output(1, "short"));
    await acked;
    expect(acks).toEqual([0, 1]);
  });

  it("does not take a snapshot of an ended shell for a running one", async () => {
    const { host, emit, screen } = attached();
    emit({ ...running(4, "last words"), snapshot: { history: "last words", status: "exited" } });
    await host.settled();
    expect(screen()).toContain("[process exited]");
  });
});

describe("terminal drawer", () => {
  it("sizes the emulator to the drawer and clamps resizing", async () => {
    const { host, terminal } = boot(40);
    host.dispatch("terminal.toggle");
    await host.settled();
    // 40% of the window, minus four rows of chrome for the screen.
    expect(terminal()).toMatchObject({ open: true, height: 16, rows: 12 });
    host.dispatch("terminal.resize", { delta: -100 });
    expect(terminal().height).toBe(6);
    host.dispatch("terminal.resize", { delta: 100 });
    // The layout keeps the status line, the prompt and a few timeline rows.
    expect(terminal().height).toBe(28);
    host.destroy();
  });

  it("offers only the terminal commands that apply", async () => {
    const { host, titles } = boot();
    expect(titles()).toEqual(expect.arrayContaining(["Show terminal", "New terminal"]));
    expect(titles()).not.toContain("Clear terminal");
    host.dispatch("terminal.toggle");
    await host.settled();
    expect(titles()).toEqual(
      expect.arrayContaining([
        "Hide terminal",
        "Clear terminal",
        "Restart terminal",
        "Close terminal",
      ]),
    );
    expect(titles()).not.toContain("Next terminal");
    host.dispatch("terminal.new");
    await host.settled();
    expect(titles()).toEqual(expect.arrayContaining(["Next terminal", "Previous terminal"]));
    host.destroy();
  });

  it("keeps one emulator per tab and resizes the server side only for the shown one", async () => {
    const { host, calls } = boot();
    host.dispatch("terminal.toggle");
    host.dispatch("terminal.new");
    await host.settled();
    const resized = () =>
      calls.filter((call) => call.method === "terminalResize").map((call) => call.args[1]);
    expect(resized()).toEqual(["term-1", "term-2"]);
    host.resize({ columns: 160, rows: 40 });
    await host.settled();
    expect(resized().at(-1)).toBe("term-2");
    expect(resized().filter((id) => id === "term-1")).toHaveLength(1);
    host.destroy();
  });
});

import { describe, expect, it } from "bun:test";

import { fakeClient } from "../../features/support/fakeClient.ts";
import { createHost } from "./host.ts";
import { terminalNumber } from "./terminalState.ts";

function boot(rows = 40) {
  const fake = fakeClient();
  const host = createHost({ client: fake.client, size: { columns: 140, rows }, log: () => {} });
  fake.connect();
  host.dispatch("thread.open", { key: "local:t1" });
  const terminal = () => host.state.get("terminal") as any;
  // The palette lists the terminal entries among the rest.
  const titles = () => {
    host.dispatch("palette.open");
    const items = (host.state.get("palette") as { items: Array<{ title: string }> }).items;
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

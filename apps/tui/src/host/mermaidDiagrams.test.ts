import { describe, expect, it } from "bun:test";
import type { MermaidRenderResult } from "@hal-c2/contracts";

import { createMermaidDiagrams } from "./mermaidDiagrams.ts";

const fakeMc = (answer: (source: string) => Promise<MermaidRenderResult>) => {
  const calls: Array<{ method: string; payload: unknown }> = [];
  return {
    calls,
    mcCall: <T>(method: string, payload: unknown) => {
      calls.push({ method, payload });
      return answer((payload as { source: string }).source) as Promise<T>;
    },
  };
};

describe("createMermaidDiagrams", () => {
  it("asks the MC once for text and keeps its answer", async () => {
    const mc = fakeMc(async () => ({ status: "drawn", kind: "flowchart", text: "A──►B" }));
    const diagrams = createMermaidDiagrams(mc);
    let changes = 0;
    diagrams.listen(() => changes++);
    expect(diagrams.get("flowchart LR\n A-->B")).toBeUndefined();
    expect(diagrams.get("flowchart LR\n A-->B")).toBeUndefined();
    await diagrams.settled();
    expect(diagrams.get("flowchart LR\n A-->B")).toEqual({
      status: "drawn",
      kind: "flowchart",
      text: "A──►B",
    });
    expect(changes).toBe(1);
    expect(mc.calls).toEqual([
      { method: "mermaid.render", payload: { source: "flowchart LR\n A-->B", format: "text" } },
    ]);
  });

  it("keeps a refused call as not drawn instead of asking again", async () => {
    const mc = fakeMc(async () => {
      throw new Error("The MC is not connected.");
    });
    const diagrams = createMermaidDiagrams(mc);
    diagrams.get("pie");
    await diagrams.settled();
    expect(diagrams.get("pie")).toEqual({
      status: "failed",
      kind: null,
      reason: "Not drawn: The MC is not connected.",
    });
    expect(mc.calls).toHaveLength(1);
  });

  it("asks again for what a lost connection refused once it is back", async () => {
    let connected = false;
    const mc = fakeMc(async () => {
      if (!connected) throw new Error("The MC is not connected.");
      return { status: "drawn", kind: "pie", text: "◔" };
    });
    const diagrams = createMermaidDiagrams(mc);
    let changes = 0;
    diagrams.listen(() => changes++);
    diagrams.get("pie");
    await diagrams.settled();
    connected = true;
    diagrams.retry();
    expect(changes).toBe(2);
    expect(diagrams.get("pie")).toBeUndefined();
    await diagrams.settled();
    expect(diagrams.get("pie")).toEqual({ status: "drawn", kind: "pie", text: "◔" });
    diagrams.retry();
    expect(changes).toBe(3);
    expect(mc.calls).toHaveLength(2);
  });

  it("keeps every diagram on screen, however many, and makes room from the others", async () => {
    const mc = fakeMc(async (source) => ({ status: "drawn", kind: "flowchart", text: source }));
    const diagrams = createMermaidDiagrams(mc);
    const screen = Array.from({ length: 300 }, (_, index) => `on screen ${index}`);
    let renders = 0;
    // Like a pane: every answer redraws it, asking for each diagram it shows.
    const render = () => {
      renders++;
      for (const source of screen) diagrams.get(source);
    };
    for (let index = 0; index < 10; index++) diagrams.get(`scrolled away ${index}`);
    await diagrams.settled();
    diagrams.listen(render);
    render();
    await diagrams.settled();
    expect(renders).toBeLessThan(400);
    expect(screen.every((source) => diagrams.get(source)?.status === "drawn")).toBe(true);
    expect(mc.calls).toHaveLength(310);
    // Off screen and older than the room allows: asked again when shown again.
    diagrams.get("scrolled away 0");
    expect(mc.calls).toHaveLength(311);
  });
});

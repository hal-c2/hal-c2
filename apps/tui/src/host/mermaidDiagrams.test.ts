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
});

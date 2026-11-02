// Mermaid diagrams where the terminal shows them (features/space/markdown.feature,
// timeline/markdown.feature, files/file-viewer-and-editing.feature): what is said of
// a diagram, whichever pane holds it. The When that puts the diagram on screen says
// where it is (`MermaidWorld.diagram`); these read it there. The MC's answers are
// fakeMermaid.ts.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { mermaidAnswer, mermaidAsks, mermaidDrawing } from "../fakeMermaid.ts";
import type { World } from "../world.ts";

export interface MermaidWorld extends World {
  /** The diagram on screen: its source, and the lines of the pane showing it. */
  diagram?: { readonly source: string; readonly lines: () => Promise<string[]> };
}

const shown = async (ctx: MermaidWorld) => {
  expect(ctx.diagram).toBeDefined();
  return { source: ctx.diagram!.source, lines: await ctx.diagram!.lines() };
};
const holds = (lines: string[], text: string) => lines.some((line) => line.includes(text));
/** A reason, which wraps to the pane, is on screen. */
const says = (lines: string[], text: string) =>
  lines
    .map((line) => line.trim())
    .join(" ")
    .includes(text);

/** Each of the diagram's source lines is on screen, in order. */
export async function expectSource(ctx: MermaidWorld) {
  const { source, lines } = await shown(ctx);
  let at = 0;
  for (const text of source.split("\n")) {
    const found = lines.findIndex((line, index) => index >= at && line.includes(text));
    expect({ missing: text, found: found >= 0 }).toEqual({ missing: text, found: true });
    at = found + 1;
  }
}

// The desktop and the phone draw the picture; their own runners prove it.
step(
  /^on the desktop and the phone the (?:flowchart|diagram) is drawn(?: in place of the code block)?$/,
  () => {},
);

step(
  "in the terminal the diagram is drawn in characters, or its source is shown, named as a {string} diagram",
  async (ctx: MermaidWorld, type: string) => {
    const { source, lines } = await shown(ctx);
    expect(holds(lines, `◇ ${type} diagram`)).toBe(true);
    const answer = mermaidAnswer(source);
    if (answer.status === "drawn") {
      for (const text of mermaidDrawing(source)) {
        if (text.trim() !== "") expect(holds(lines, text.trimEnd())).toBe(true);
      }
    } else {
      expect(says(lines, answer.reason)).toBe(true);
      await expectSource(ctx);
    }
  },
);

step("the diagram's source is shown", expectSource);

step("the user is told where the mistake is", async (ctx: MermaidWorld) => {
  const { source, lines } = await shown(ctx);
  const answer = mermaidAnswer(source);
  expect(answer.status).toBe("invalid");
  if (answer.status !== "invalid") return;
  expect(says(lines, `Line ${answer.line}, column ${answer.column}: ${answer.reason}`)).toBe(true);
});

step("nothing claims the diagram is still being drawn", async (ctx: MermaidWorld) => {
  const { lines } = await shown(ctx);
  expect(holds(lines, "drawing…")).toBe(false);
});

step(
  "the user is told {string} diagrams cannot be drawn yet",
  async (ctx: MermaidWorld, type: string) => {
    const { lines } = await shown(ctx);
    expect(says(lines, `${type} diagrams cannot be drawn yet.`)).toBe(true);
  },
);

step("the diagram is not drawn again", (ctx: MermaidWorld) => {
  expect(mermaidAsks(ctx, ctx.diagram!.source)).toBe(1);
});

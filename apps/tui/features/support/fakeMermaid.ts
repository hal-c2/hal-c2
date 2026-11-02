// The MC's `mermaid.render` for text, as its helper (native/mermaid) answers these
// sources: the scenarios' diagrams, synthetic, and each one's real answer. A source not
// here is answered as a mistake on line 1, so a scenario that strays shows it.
import type { MermaidRenderResult } from "@hal-c2/contracts";

import type { World } from "./world.ts";

/** A diagram of each type the scenarios name, by type. */
export const MERMAID_SOURCES: Record<string, string> = {
  flowchart: "flowchart LR\n  Cart --> Checkout --> Paid",
  graph: "graph TD\n  Cart --> Paid",
  sequenceDiagram: "sequenceDiagram\n  Shop->>Bank: charge\n  Bank-->>Shop: ok",
  "stateDiagram-v2": "stateDiagram-v2\n  [*] --> Cart\n  Cart --> Paid",
  gantt: "gantt\n  title Launch\n  section Build\n  Pages :a1, 2026-07-01, 7d",
  "block-beta": "block-beta\n  Cart Paid",
};

/** A flowchart with an unclosed bracket. */
export const BROKEN_FLOWCHART = "flowchart LR\n  A[Cart --> B";
/** The flowchart with a node added. */
export const GROWN_FLOWCHART = `${MERMAID_SOURCES.flowchart}\n  Paid --> Shipped`;

const ANSWERS: Record<string, MermaidRenderResult> = {
  [MERMAID_SOURCES.flowchart!]: {
    status: "drawn",
    kind: "flowchart",
    text: "┌──────┐      ┌──────────┐     ┌──────┐\n│ Cart │─────►│ Checkout │────►│ Paid │\n└──────┘      └──────────┘     └──────┘",
  },
  [MERMAID_SOURCES.graph!]: {
    status: "drawn",
    kind: "graph",
    text: "┌──────┐\n│ Cart │\n└──────┘\n    │\n    │\n    ▼\n┌──────┐\n│ Paid │\n└──────┘",
  },
  [MERMAID_SOURCES.sequenceDiagram!]: {
    status: "drawn",
    kind: "sequenceDiagram",
    text: "┌──────┐            ┌──────┐\n│ Shop │            │ Bank │\n└───┬──┘            └───┬──┘\n    │                   │\n    │─charge───────────>│\n    │                   │\n    │<┄ok┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄│\n    │                   │",
  },
  [MERMAID_SOURCES["stateDiagram-v2"]!]: {
    status: "drawn",
    kind: "stateDiagram-v2",
    text: "    ●\n\n    │\n    │\n    ▼\n╭──────╮\n│ Cart │\n╰──────╯\n    │\n    │\n    ▼\n╭──────╮\n│ Paid │\n╰──────╯",
  },
  [MERMAID_SOURCES.gantt!]: {
    status: "unsupported",
    kind: "gantt",
    reason: "gantt diagrams have no text drawing yet.",
  },
  [MERMAID_SOURCES["block-beta"]!]: {
    status: "unsupported",
    kind: "block-beta",
    reason: "block-beta diagrams cannot be drawn yet.",
  },
  [BROKEN_FLOWCHART]: {
    status: "invalid",
    kind: "flowchart",
    reason: "expected EOI, shape, class_annotation, edge_connector, statement, or comment",
    line: 2,
    column: 4,
  },
  [GROWN_FLOWCHART]: {
    status: "drawn",
    kind: "flowchart",
    text: "┌──────┐      ┌──────────┐     ┌──────┐      ┌─────────┐\n│ Cart │─────►│ Checkout │────►│ Paid │─────►│ Shipped │\n└──────┘      └──────────┘     └──────┘      └─────────┘",
  },
};

/** What the MC answers for `source`. */
export const mermaidAnswer = (source: string): MermaidRenderResult =>
  ANSWERS[source] ?? { status: "invalid", kind: null, reason: "not a diagram", line: 1 };

/** The lines the MC drew `source` in. */
export const mermaidDrawing = (source: string): string[] => {
  const answer = mermaidAnswer(source);
  if (answer.status !== "drawn" || answer.text === undefined) {
    throw new Error(`the MC does not draw ${JSON.stringify(source)}`);
  }
  return answer.text.split("\n");
};

/** The MC draws diagrams for the scenario's client, running or about to start. */
export function serveMermaid(ctx: World) {
  const serve = () =>
    ctx.fake!.settings.on("mermaid.render", (payload) => {
      const { source, format } = payload as { source: string; format?: string };
      if (format !== "text") throw new Error("the terminal asks for text");
      return mermaidAnswer(source);
    });
  if (ctx.fake) serve();
  const previous = ctx.prepare;
  ctx.prepare = () => {
    previous?.();
    serve();
  };
}

/** A Markdown fence holding `source`. */
export const mermaidFence = (source: string) => `\`\`\`mermaid\n${source}\n\`\`\``;

/** How often the client asked the MC to draw `source`. */
export const mermaidAsks = (ctx: World, source: string) =>
  ctx
    .fake!.settings.callsTo("mermaid.render")
    .filter((call) => (call.payload as { source: string }).source === source).length;

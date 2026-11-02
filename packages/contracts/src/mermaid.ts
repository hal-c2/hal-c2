import * as Schema from "effect/Schema";

/**
 * A Mermaid diagram drawn by the MC (`HalC2.Mermaid`), the one renderer every client
 * shows diagrams with: in a page, a reply and the file viewer. The MC keeps what it
 * drew by the request's hash, so asking again costs nothing; a client keeps it too, so
 * it asks once per source.
 */
export const MermaidRenderInput = Schema.Struct({
  source: Schema.String,
  /** An SVG for the desktop and the phone, text for the terminal. Defaults to "svg". */
  format: Schema.optional(Schema.Literals(["svg", "text"])),
  /** Defaults to "light". */
  theme: Schema.optional(Schema.Literals(["light", "dark"])),
});
export type MermaidRenderInput = typeof MermaidRenderInput.Type;

/** The diagram's type, its first word ("flowchart", "sequenceDiagram"); null when there is none. */
const MermaidKind = Schema.NullOr(Schema.String);

export const MermaidDrawn = Schema.Struct({
  status: Schema.Literal("drawn"),
  kind: Schema.String,
  /** For "svg": the drawing and its size in pixels. */
  svg: Schema.optional(Schema.String),
  width: Schema.optional(Schema.Number),
  height: Schema.optional(Schema.Number),
  /** For "text": the drawing in monospaced characters. */
  text: Schema.optional(Schema.String),
});
export type MermaidDrawn = typeof MermaidDrawn.Type;

/**
 * Not drawn. "unsupported": a type (or a type's text drawing) the renderer lacks.
 * "invalid": a mistake in the source, at a 1-based line and column when known.
 * "failed": the renderer gave no drawing; asking again tries again.
 */
export const MermaidNotDrawn = Schema.Struct({
  status: Schema.Literals(["unsupported", "invalid", "failed"]),
  kind: MermaidKind,
  /** What to tell the user. */
  reason: Schema.String,
  line: Schema.optional(Schema.NullOr(Schema.Number)),
  column: Schema.optional(Schema.NullOr(Schema.Number)),
});
export type MermaidNotDrawn = typeof MermaidNotDrawn.Type;

export const MermaidRenderResult = Schema.Union([MermaidDrawn, MermaidNotDrawn]);
export type MermaidRenderResult = typeof MermaidRenderResult.Type;

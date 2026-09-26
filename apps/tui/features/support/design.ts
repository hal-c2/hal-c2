// Helpers for scenarios that pin the OpenTUI client's look: the rendered rows
// of one object, a docstring-friendly block compare, and the style of a cell.
import { expect } from "bun:test";
import type { CapturedSpan } from "@opentui/core";

import { findObject, snapshot, type World } from "./world.ts";

interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

/** Where a named object was drawn, in screen cells. */
export function rectOf(ctx: World, objectName: string): Rect {
  const { x, y, width, height } = (findObject(ctx, objectName) as unknown as { renderable: Rect })
    .renderable;
  return { x, y, width, height };
}

/** Every rendered row as cells: one grapheme and its span per column. */
async function cells(ctx: World): Promise<Array<Array<{ text: string; span: CapturedSpan }>>> {
  await snapshot(ctx);
  return ctx.app!.setup.captureSpans().lines.map((line) => {
    const row: Array<{ text: string; span: CapturedSpan }> = [];
    for (const span of line.spans) {
      const glyphs = [...span.text];
      if (glyphs.length === span.width) for (const text of glyphs) row.push({ text, span });
      else {
        // A wide grapheme fills two columns; keep the columns lined up.
        row.push({ text: span.text, span });
        for (let pad = 1; pad < span.width; pad += 1) row.push({ text: "", span });
      }
    }
    return row;
  });
}

/** The rows the object covers, cut to its columns. */
export async function objectRows(ctx: World, objectName: string): Promise<string[]> {
  const rows = await cells(ctx);
  const rect = rectOf(ctx, objectName);
  return rows.slice(rect.y, rect.y + rect.height).map((row) =>
    row
      .slice(rect.x, rect.x + rect.width)
      .map((cell) => cell.text)
      .join(""),
  );
}

/** Right-trimmed, blank ends dropped, common indent removed. */
export function block(lines: readonly string[]): string {
  const trimmed = lines.map((line) => line.trimEnd());
  while (trimmed.length > 0 && trimmed[0] === "") trimmed.shift();
  while (trimmed.length > 0 && trimmed.at(-1) === "") trimmed.pop();
  const indent = Math.min(
    ...trimmed.filter((line) => line !== "").map((line) => line.length - line.trimStart().length),
  );
  return trimmed.map((line) => line.slice(indent)).join("\n");
}

/** The cell at a screen position. */
export async function cellAt(
  ctx: World,
  x: number,
  y: number,
): Promise<{ text: string; span: CapturedSpan }> {
  const cell = (await cells(ctx))[y]?.[x];
  if (!cell) throw new Error(`no cell at ${x},${y}`);
  return cell;
}

/** The first cell showing `glyph` on the first row that contains `rowText`. */
export async function cellOn(
  ctx: World,
  rowText: string,
  glyph: string,
): Promise<{ x: number; y: number; span: CapturedSpan }> {
  const rows = await cells(ctx);
  for (const [y, row] of rows.entries()) {
    const text = row.map((cell) => cell.text).join("");
    if (!text.includes(rowText)) continue;
    const x = row.findIndex((cell) => cell.text === glyph);
    if (x >= 0) return { x, y, span: row[x]!.span };
  }
  throw new Error(`no row shows "${rowText}" with "${glyph}"`);
}

/** The screen column and row where `text` first starts. */
export async function textAt(ctx: World, text: string): Promise<{ x: number; y: number }> {
  const rows = await cells(ctx);
  for (const [y, row] of rows.entries()) {
    for (let x = 0; x < row.length; x += 1) {
      const rest = row
        .slice(x, x + text.length * 2)
        .map((cell) => cell.text)
        .join("");
      if (rest.startsWith(text)) return { x, y };
    }
  }
  throw new Error(`"${text}" is not on screen`);
}

/** Compare colours the way the terminal sees them (palette slot, not RGB). */
export function expectColour(actual: CapturedSpan["fg"], expected: CapturedSpan["fg"]): void {
  expect({ intent: actual.intent, slot: actual.slot }).toEqual({
    intent: expected.intent,
    slot: expected.slot,
  });
}

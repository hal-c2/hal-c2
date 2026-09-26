import type { ImagePreview } from "@hal-c2/opentui-image";

import { clip } from "../format.ts";
import type { TuiSize } from "./layoutState.ts";
import { FALLBACK_CELL_PIXELS, type CellPixels } from "./timelineState.ts";

/**
 * Published under `imageViewer` (null when closed): an image attachment open
 * full size in the conversation pane's place (ImageLightbox), `columns` ×
 * `rows` cells with the image's aspect kept. Esc or a click closes it
 * (`image.close`).
 */
export interface TuiImageViewerState {
  readonly id: string;
  /** `name · 12 KB`, the name clipped to leave room for the hint. */
  readonly title: string;
  readonly hint: string;
  readonly source: Uint8Array;
  readonly columns: number;
  readonly rows: number;
}

/** The largest `columns` × `rows` box within the bounds that keeps the image's aspect. */
export function fitImageToCells(input: {
  readonly imageWidth: number;
  readonly imageHeight: number;
  readonly maxColumns: number;
  readonly maxRows: number;
  readonly cellWidth: number;
  readonly cellHeight: number;
}): { readonly columns: number; readonly rows: number } {
  const maxColumns = Math.max(1, Math.floor(input.maxColumns));
  const maxRows = Math.max(1, Math.floor(input.maxRows));
  const cellWidth = input.cellWidth > 0 ? input.cellWidth : FALLBACK_CELL_PIXELS.width;
  const cellHeight = input.cellHeight > 0 ? input.cellHeight : FALLBACK_CELL_PIXELS.height;
  let columns = maxColumns;
  let rows = Math.max(
    1,
    Math.round((input.imageHeight / input.imageWidth) * columns * (cellWidth / cellHeight)),
  );
  if (rows > maxRows) {
    rows = maxRows;
    columns = Math.max(
      1,
      Math.round((input.imageWidth / input.imageHeight) * rows * (cellHeight / cellWidth)),
    );
  }
  return { columns: Math.min(columns, maxColumns), rows: Math.min(rows, maxRows) };
}

// The viewer's border and header row.
const VIEWER_CHROME_COLUMNS = 4;
const VIEWER_CHROME_ROWS = 4;

export function buildImageViewerState(input: {
  readonly attachment: { readonly id: string; readonly name: string; readonly sizeBytes: number };
  readonly image: ImagePreview;
  /** The conversation pane the preview fills. */
  readonly size: TuiSize;
  readonly cellPixels: CellPixels | null;
}): TuiImageViewerState {
  const cell = input.cellPixels ?? FALLBACK_CELL_PIXELS;
  const fitted = fitImageToCells({
    imageWidth: input.image.imageWidth,
    imageHeight: input.image.imageHeight,
    maxColumns: input.size.columns - VIEWER_CHROME_COLUMNS,
    maxRows: input.size.rows - VIEWER_CHROME_ROWS,
    cellWidth: cell.width,
    cellHeight: cell.height,
  });
  const sizeKb = Math.max(1, Math.round(input.attachment.sizeBytes / 1024));
  const hint = input.size.columns >= 48 ? "Esc / click to close" : "Esc close";
  const metadataWidth = Math.max(4, input.size.columns - hint.length - 9);
  return {
    id: input.attachment.id,
    title: `${clip(input.attachment.name, metadataWidth)} · ${sizeKb} KB`,
    hint,
    source: input.image.source,
    ...fitted,
  };
}

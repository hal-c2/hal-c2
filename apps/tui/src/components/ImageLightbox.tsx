import type { ImagePreview } from "@t3tools/opentui-image";
import { useRenderer } from "@opentui/react";
import * as React from "react";

import { clip } from "../format.ts";
import { fitImageToCells } from "../host/imageViewer.ts";
import { deferMouseAction } from "../mouse.ts";
import { usePalette } from "../theme.ts";

const FALLBACK_CELL_WIDTH = 18;
const FALLBACK_CELL_HEIGHT = 35;

export interface ExpandedImagePreview {
  readonly name: string;
  readonly sizeBytes: number;
  readonly image: ImagePreview;
}

export { fitImageToCells };

export const ImageLightbox = React.memo(function ImageLightbox({
  preview,
  width,
  height,
  onClose,
}: {
  readonly preview: ExpandedImagePreview;
  readonly width: number;
  readonly height: number;
  readonly onClose: () => void;
}): React.ReactNode {
  const palette = usePalette();
  const renderer = useRenderer();
  const cellWidth = renderer.resolution
    ? renderer.resolution.width / renderer.width
    : FALLBACK_CELL_WIDTH;
  const cellHeight = renderer.resolution
    ? renderer.resolution.height / renderer.height
    : FALLBACK_CELL_HEIGHT;
  const fitted = fitImageToCells({
    imageWidth: preview.image.imageWidth,
    imageHeight: preview.image.imageHeight,
    maxColumns: width - 4,
    maxRows: height - 4,
    cellWidth,
    cellHeight,
  });
  const sizeKb = Math.max(1, Math.round(preview.sizeBytes / 1024));
  const closeHint = width >= 48 ? "Esc / click to close" : "Esc close";
  const metadataWidth = Math.max(4, width - closeHint.length - 9);
  const closeFromMouse = React.useMemo(() => deferMouseAction(onClose), [onClose]);

  return (
    <box
      flexDirection="column"
      width={width}
      height={height}
      border
      borderStyle="rounded"
      borderColor={palette.accent}
      alignItems="center"
      onMouseDown={closeFromMouse}
    >
      <box width={Math.max(1, width - 4)} flexDirection="row" justifyContent="space-between">
        <text fg={palette.text}>{`${clip(preview.name, metadataWidth)} · ${sizeKb} KB`}</text>
        <text fg={palette.dim}>{closeHint}</text>
      </box>
      <box flexGrow={1} width={Math.max(1, width - 2)} alignItems="center" justifyContent="center">
        <image
          source={preview.image.source}
          width={fitted.columns}
          height={fitted.rows}
          fit="fill"
        />
      </box>
    </box>
  );
});

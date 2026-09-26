import type { ContextMenuItem } from "@hal-c2/contracts";
import { RGBA, type MouseEvent } from "@opentui/core";
import * as React from "react";

import { clip } from "../format.ts";
import {
  contextMenuIndexAtRow,
  isSelectable,
  resolveContextMenuLayout,
  type ContextMenuPosition,
} from "./ContextMenu.logic.ts";
import { usePalette } from "../theme.ts";

const TRANSPARENT = RGBA.fromValues(0, 0, 0, 0);

export {
  contextMenuIndexAtRow,
  firstContextMenuIndex,
  moveContextMenuIndex,
  resolveContextMenuLayout,
  type ContextMenuLayout,
  type ContextMenuPosition,
} from "./ContextMenu.logic.ts";

export const ContextMenu = React.memo(function ContextMenu({
  items,
  selectedIndex,
  position,
  viewport,
  onSelectIndex,
  onRun,
  onClose,
}: {
  readonly items: ReadonlyArray<ContextMenuItem>;
  readonly selectedIndex: number;
  readonly position: ContextMenuPosition;
  readonly viewport: { readonly width: number; readonly height: number };
  readonly onSelectIndex: (index: number) => void;
  readonly onRun: (item: ContextMenuItem) => void;
  readonly onClose: () => void;
}): React.ReactNode {
  const palette = usePalette();
  const layout = resolveContextMenuLayout(items, position, viewport);
  const labelWidth = Math.max(1, layout.width - 4);
  const stopMouse = (event: MouseEvent) => event.stopPropagation();

  return (
    <box
      position="absolute"
      top={0}
      left={0}
      width={viewport.width}
      height={viewport.height}
      zIndex={100}
    >
      <box
        position="absolute"
        top={0}
        left={0}
        width={viewport.width}
        height={viewport.height}
        backgroundColor={TRANSPARENT}
        onMouseDown={onClose}
      />
      <box
        position="absolute"
        top={layout.y}
        left={layout.x}
        width={layout.width}
        height={layout.height}
        flexDirection="column"
        border
        borderStyle="rounded"
        borderColor={palette.faint}
        paddingLeft={1}
        paddingRight={1}
        overflow="hidden"
        onMouseMove={(event) => {
          const index = contextMenuIndexAtRow(items, event.y - layout.y);
          if (index !== null && isSelectable(items[index])) onSelectIndex(index);
        }}
        onMouseDown={(event) => {
          stopMouse(event);
          const index = contextMenuIndexAtRow(items, event.y - layout.y);
          const item = index === null ? undefined : items[index];
          if (isSelectable(item)) onRun(item);
        }}
      >
        {items.map((item, index) => {
          const active = index === selectedIndex && isSelectable(item);
          const color = item.destructive
            ? palette.error
            : item.disabled || item.header
              ? palette.faint
              : active
                ? palette.text
                : palette.dim;
          return (
            <React.Fragment key={item.id}>
              {item.separatorBefore ? (
                <text fg={palette.faint}>{"─".repeat(labelWidth)}</text>
              ) : null}
              <box backgroundColor={active ? palette.selectedBg : palette.bg}>
                <text>
                  <span fg={active ? palette.accent : palette.faint}>{active ? "▸ " : "  "}</span>
                  <span fg={color}>{clip(item.label, labelWidth - 2)}</span>
                </text>
              </box>
            </React.Fragment>
          );
        })}
      </box>
    </box>
  );
});

import type { ContextMenuItem } from "@hal-c2/contracts";

// Pure context-menu geometry and keyboard stepping, shared by the React menu
// and the QML shell host.

export interface ContextMenuPosition {
  readonly x: number;
  readonly y: number;
}

export interface ContextMenuLayout extends ContextMenuPosition {
  readonly width: number;
  readonly height: number;
}

export function resolveContextMenuLayout(
  items: ReadonlyArray<ContextMenuItem>,
  position: ContextMenuPosition,
  viewport: { readonly width: number; readonly height: number },
): ContextMenuLayout {
  const labelWidth = Math.max(1, ...items.map((item) => item.label.length));
  const width = Math.min(viewport.width, Math.max(12, labelWidth + 6));
  const separatorCount = items.filter((item) => item.separatorBefore).length;
  const height = Math.min(viewport.height, items.length + separatorCount + 2);
  return {
    x: Math.max(0, Math.min(position.x, viewport.width - width)),
    y: Math.max(0, Math.min(position.y, viewport.height - height)),
    width,
    height,
  };
}

export function isSelectable(item: ContextMenuItem | undefined): item is ContextMenuItem {
  return item !== undefined && item.disabled !== true && item.header !== true;
}

export function firstContextMenuIndex(items: ReadonlyArray<ContextMenuItem>): number {
  const index = items.findIndex(isSelectable);
  return index < 0 ? 0 : index;
}

export function moveContextMenuIndex(
  items: ReadonlyArray<ContextMenuItem>,
  selectedIndex: number,
  direction: -1 | 1,
): number {
  if (items.length === 0) return 0;
  for (let offset = 1; offset <= items.length; offset += 1) {
    const index = (selectedIndex + direction * offset + items.length) % items.length;
    if (isSelectable(items[index])) return index;
  }
  return selectedIndex;
}

export function contextMenuIndexAtRow(
  items: ReadonlyArray<ContextMenuItem>,
  row: number,
): number | null {
  let cursor = 1;
  for (let index = 0; index < items.length; index += 1) {
    if (items[index]?.separatorBefore) cursor += 1;
    if (row === cursor) return index;
    cursor += 1;
  }
  return null;
}

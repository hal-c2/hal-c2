import { resolveChatColumnLayout, type ChatColumnLayout } from "../components/ChatView.layout.ts";
import type { KeyBindingMode } from "../hooks/useKeyBindings.ts";

/** `list`: the thread list has the keys (its "list" keymap is live). */
export type TuiMode = KeyBindingMode | "list";

export interface TuiSize {
  readonly columns: number;
  readonly rows: number;
}

/** Published under `layout`: the contract's collapse flag plus the column split. */
export interface TuiLayoutState extends ChatColumnLayout {
  readonly sidebarCollapsed: boolean;
  /**
   * Too narrow to dock the thread list, and the filter is open: the list
   * takes the whole width in place of the conversation.
   */
  readonly sidebarAsMain: boolean;
}

export function buildTuiLayoutState(input: {
  readonly size: TuiSize;
  readonly sidebarCollapsed: boolean;
  readonly rightPanelVisible: boolean;
  readonly mode: TuiMode;
}): TuiLayoutState {
  const columns = resolveChatColumnLayout(
    input.size.columns,
    input.rightPanelVisible,
    input.sidebarCollapsed,
  );
  return {
    ...columns,
    sidebarCollapsed: input.sidebarCollapsed,
    sidebarAsMain: !columns.sidebarVisible && input.mode === "filter",
  };
}

import {
  CHAT_CONTENT_MAX_WIDTH,
  COMPOSER_MIN_EDITOR_ROWS,
  resolveChatColumnLayout,
  resolveChatVerticalLayout,
  type ChatColumnLayout,
  type ChatVerticalLayout,
} from "../components/ChatView.layout.ts";
import type { KeyBindingMode } from "../hooks/useKeyBindings.ts";

/** Key-routing modes: the old TUI's focus modes, the new-thread draft, and `list` (the thread list
 * has the keys; its "list" keymap is live). */
export type TuiMode = KeyBindingMode | "newThread" | "list";

export interface TuiSize {
  readonly columns: number;
  readonly rows: number;
}

/** Composer borders, footer and dock spacing around the editor rows (ChatView's measure). */
const COMPOSER_CHROME_ROWS = 4;

/** ChatView's composer surface: the conversation column less a cell each side, 8 to 96 wide. */
export const composerSurfaceWidth = (chatWidth: number): number =>
  Math.max(8, Math.min(CHAT_CONTENT_MAX_WIDTH, chatWidth - 2));

/**
 * Published under `layout`: the contract's collapse flag, the column split,
 * and the row split of the main column.
 */
export interface TuiLayoutState extends ChatColumnLayout, ChatVerticalLayout {
  readonly sidebarCollapsed: boolean;
  /**
   * Too narrow to dock the thread list, and the filter is open: the list
   * takes the whole width in place of the conversation.
   */
  readonly sidebarAsMain: boolean;
  /**
   * The detail panel slot (`ShellWindow.rightPanelComponent`). `kind` names
   * the panel the host opened ("sourceControl"); `asMain` means
   * the main column is too narrow to share, so the panel replaces the
   * conversation until it closes. `focused` says the panel has the keys.
   */
  readonly rightPanel: {
    readonly visible: boolean;
    readonly kind: string | null;
    readonly asMain: boolean;
    readonly width: number;
    readonly focused: boolean;
  };
  /** The terminal drawer slot (`ShellWindow.drawerComponent`) under the conversation. */
  readonly drawer: { readonly open: boolean; readonly rows: number };
  /** The conversation and prompt column: capped at 96 cells and centred in `chatWidth`. */
  readonly contentWidth: number;
  readonly contentOffset: number;
}

export interface TuiLayoutInput {
  readonly size: TuiSize;
  readonly sidebarCollapsed: boolean;
  readonly rightPanel: string | null;
  readonly rightPanelFocused?: boolean;
  readonly mode: TuiMode;
  readonly drawerOpen?: boolean;
  /** The user's drawer height; defaults to 40% of the terminal. */
  readonly drawerRows?: number | null;
  /** The editor rows the composer wants (its text's wrapped height, 3–8, or the user's). */
  readonly editorRows?: number | undefined;
  /** Rows a picker or popover above the prompt wants. */
  readonly popoverRows?: number;
  /**
   * A popover or context menu is open, or the prompt is a one-line rename,
   * commit or filter field: the editor takes one row (ChatView).
   */
  readonly oneLineEditor?: boolean;
  /** The composer's rows besides the editor (question, attachments, compact footer, context). */
  readonly composerChromeRows?: number | undefined;
}

export function buildTuiLayoutState(input: TuiLayoutInput): TuiLayoutState {
  const { size } = input;
  const columns = resolveChatColumnLayout(
    size.columns,
    input.rightPanel !== null,
    input.sidebarCollapsed,
  );
  const contentWidth = Math.min(CHAT_CONTENT_MAX_WIDTH, columns.chatWidth);
  const popoverRows = input.popoverRows ?? 0;
  const vertical = resolveChatVerticalLayout({
    terminalHeight: size.rows,
    desiredEditorRows:
      popoverRows > 0 || input.oneLineEditor === true
        ? 1
        : (input.editorRows ?? COMPOSER_MIN_EDITOR_ROWS),
    composerChromeRows: input.composerChromeRows ?? COMPOSER_CHROME_ROWS,
    terminalOpen: input.drawerOpen === true,
    preferredTerminalRows: input.drawerRows ?? Math.floor(size.rows * 0.4),
    wantedPopoverRows: popoverRows,
  });
  return {
    ...columns,
    ...vertical,
    sidebarCollapsed: input.sidebarCollapsed,
    sidebarAsMain: !columns.sidebarVisible && input.mode === "filter",
    rightPanel: {
      visible: input.rightPanel !== null,
      kind: input.rightPanel,
      asMain: columns.rightPanelAsMain,
      width: columns.rightPanelAsMain ? columns.mainWidth : columns.rightWidth,
      focused: input.rightPanel !== null && input.rightPanelFocused === true,
    },
    drawer: { open: input.drawerOpen === true, rows: vertical.terminalRows },
    contentWidth,
    contentOffset: Math.floor((columns.chatWidth - contentWidth) / 2),
  };
}

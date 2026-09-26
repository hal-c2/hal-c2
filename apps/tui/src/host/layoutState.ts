import {
  CHAT_CONTENT_MAX_WIDTH,
  COMPOSER_MIN_EDITOR_ROWS,
  countWrappedComposerLines,
  resolveChatColumnLayout,
  resolveChatVerticalLayout,
  type ChatColumnLayout,
  type ChatVerticalLayout,
} from "../components/ChatView.layout.ts";
import type { KeyBindingMode } from "../hooks/useKeyBindings.ts";

/** Key-routing modes: the old TUI's focus modes plus the new-thread form. */
export type TuiMode = KeyBindingMode | "newThread";

export interface TuiSize {
  readonly columns: number;
  readonly rows: number;
}

/** Composer borders, footer and dock spacing around the editor rows (ChatView's measure). */
const COMPOSER_CHROME_ROWS = 4;

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
   * the panel the host opened ("sourceControl", "files", …); `asMain` means
   * the main column is too narrow to share, so the panel replaces the
   * conversation until it closes.
   */
  readonly rightPanel: {
    readonly visible: boolean;
    readonly kind: string | null;
    readonly asMain: boolean;
    readonly width: number;
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
  readonly mode: TuiMode;
  readonly drawerOpen?: boolean;
  /** The user's drawer height; defaults to 40% of the terminal. */
  readonly drawerRows?: number | null;
  /** The prompt text, for the editor's wrapped height. */
  readonly composerText?: string;
  /** Rows a picker or popover above the prompt wants. */
  readonly popoverRows?: number;
}

export function buildTuiLayoutState(input: TuiLayoutInput): TuiLayoutState {
  const { size } = input;
  const columns = resolveChatColumnLayout(
    size.columns,
    input.rightPanel !== null,
    input.sidebarCollapsed,
  );
  const contentWidth = Math.min(CHAT_CONTENT_MAX_WIDTH, columns.chatWidth);
  // ComposerDock: the editor sits inside a bordered, padded surface.
  const surfaceWidth = Math.max(8, Math.min(CHAT_CONTENT_MAX_WIDTH, columns.chatWidth - 2));
  const popoverRows = input.popoverRows ?? 0;
  const vertical = resolveChatVerticalLayout({
    terminalHeight: size.rows,
    desiredEditorRows:
      popoverRows > 0
        ? 1
        : Math.max(
            COMPOSER_MIN_EDITOR_ROWS,
            countWrappedComposerLines(input.composerText ?? "", surfaceWidth - 4),
          ),
    composerChromeRows: COMPOSER_CHROME_ROWS,
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
    },
    drawer: { open: input.drawerOpen === true, rows: vertical.terminalRows },
    contentWidth,
    contentOffset: Math.floor((columns.chatWidth - contentWidth) / 2),
  };
}

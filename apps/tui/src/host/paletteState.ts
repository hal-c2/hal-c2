import type { PropertyMap } from "opentui-qml";

import { filterCommands, type Command } from "../commands.ts";
import { clip } from "../format.ts";
import { THEME } from "../theme.ts";
import type { TuiMode } from "./layoutState.ts";
import { chunk, styled, type StyledText } from "./styledText.ts";

// The command palette (^K): a query over the commands the current context
// offers. Each command is a host action, so running one is the same as
// pressing its chord; the palette closes before the action runs so an action
// that opens another overlay (a picker, settings) is not closed again.

/** A palette entry: a title and the host action it dispatches. */
export interface PaletteCommand {
  readonly id: string;
  readonly title: string;
  readonly hint?: string;
  readonly keywords?: string;
  readonly action: string;
  readonly payload?: unknown;
}

/** Published under `palette`. */
export interface TuiPaletteState {
  readonly open: boolean;
  readonly query: string;
  readonly commands: ReadonlyArray<{
    readonly id: string;
    readonly title: string;
    readonly hint: string;
    /** The host action the entry dispatches. */
    readonly action: string;
  }>;
  readonly index: number;
  /**
   * The commands in view, as CommandPalette draws them: a window around the
   * highlighted one, each row marked, clipped and followed by its shortcut.
   */
  readonly rows: ReadonlyArray<{
    readonly index: number;
    readonly active: boolean;
    readonly text: StyledText;
  }>;
}

export interface PaletteContext {
  /** A new-thread draft is open (workspace and branch pickers apply). */
  readonly newDraft: boolean;
  readonly workspaceMode: "current" | "new-worktree" | null;
  /** The selected thread, when replying to one. */
  readonly threadId: string | null;
  readonly interactionMode: "default" | "plan";
  readonly hasProposedPlan: boolean;
  readonly attachmentCount: number;
  readonly referenceCount: number;
}

/**
 * The composer's commands in this context, in display order. The host
 * appends the thread, source-control, settings, files, add-project and
 * terminal entries after these.
 */
export function buildPaletteCommands(context: PaletteContext): PaletteCommand[] {
  const list: PaletteCommand[] = [
    { id: "new", title: "New thread", hint: "^N", action: "thread.new" },
  ];
  const composing = context.newDraft || context.threadId !== null;
  if (composing) {
    list.push({
      id: "plan",
      title: context.interactionMode === "plan" ? "Switch to build mode" : "Switch to plan mode",
      hint: "^B",
      keywords: "interaction mode",
      action: "composer.interactionMode.toggle",
    });
    if (context.newDraft) {
      list.push(
        {
          id: "workspace",
          title: "Change workspace",
          keywords: "checkout worktree",
          action: "composer.workspacePicker.toggle",
        },
        {
          id: "branch",
          title: context.workspaceMode === "new-worktree" ? "Change base branch" : "Change branch",
          keywords: "git ref",
          action: "composer.branchPicker.toggle",
        },
      );
    }
    list.push(
      { id: "model", title: "Change model", hint: "^⇧M", action: "composer.modelPicker.toggle" },
      {
        id: "reasoning",
        title: "Change reasoning effort",
        hint: "^⇧E",
        keywords: "effort thinking",
        action: "composer.effortPicker.toggle",
      },
      {
        id: "options",
        title: "Change model options",
        keywords: "traits fast mode thinking provider settings",
        action: "composer.optionsPicker.toggle",
      },
      {
        id: "runtime",
        title: "Change runtime access",
        hint: "^O",
        keywords: "permissions approval sandbox",
        action: "composer.runtimePicker.toggle",
      },
      {
        id: "editor",
        title: "Edit prompt in $EDITOR",
        hint: "^G",
        keywords: "vim editor compose",
        action: "composer.editor.open",
      },
    );
  }
  if (context.threadId !== null && context.hasProposedPlan) {
    list.push({ id: "implement", title: "Implement plan", hint: "^Y", action: "plan.implement" });
  }
  if (composing && context.referenceCount > 0) {
    list.push({
      id: "remove-reference",
      title: "Remove last file reference",
      keywords: "mention chip context",
      action: "composer.reference.remove",
    });
  }
  if (composing && context.attachmentCount > 0) {
    list.push({
      id: "remove-attachment",
      title: "Remove last attachment",
      keywords: "image clear",
      action: "composer.attachment.remove",
    });
  }
  return list;
}

export interface PaletteOptions {
  readonly state: PropertyMap;
  readonly mode: () => TuiMode;
  readonly setMode: (mode: TuiMode) => void;
  readonly context: () => PaletteContext;
  /** Entries other areas contribute, listed after the composer's. */
  readonly extraCommands?: () => ReadonlyArray<PaletteCommand>;
  /** Run a command's action through the host. */
  readonly run: (action: string, payload?: unknown) => void;
  /** The palette's inner width and the rows its list may take. */
  readonly viewport?: () => { readonly width: number; readonly maxRows: number };
}

export interface Palette {
  readonly dispatch: (action: string, payload?: unknown) => boolean;
  /** The context changed while open: re-list. */
  readonly sync: () => void;
  /** The layout gives an open palette rows above the prompt. */
  readonly isOpen: () => boolean;
}

const CLOSED: TuiPaletteState = { open: false, query: "", commands: [], index: 0, rows: [] };

/** CommandPalette's rows: a window of `maxRows` around the highlighted command. */
export function paletteRows(
  commands: ReadonlyArray<{ readonly title: string; readonly hint?: string | undefined }>,
  selectedIndex: number,
  width: number,
  maxRows: number,
): TuiPaletteState["rows"] {
  const labelRoom = Math.max(8, width - 12);
  const window = Math.max(1, maxRows);
  const start = Math.min(
    Math.max(0, selectedIndex - Math.floor(window / 2)),
    Math.max(0, commands.length - window),
  );
  return commands.slice(start, start + window).map((command, offset) => {
    const index = start + offset;
    const active = index === selectedIndex;
    return {
      index,
      active,
      text: styled(
        chunk(active ? "▸ " : "  ", { fg: active ? THEME.accent : THEME.dim }),
        chunk(clip(command.title, labelRoom), { fg: active ? THEME.text : THEME.dim }),
        command.hint ? chunk(`  ${command.hint}`, { fg: active ? THEME.bg : THEME.dim }) : null,
      ),
    };
  });
}

export function createPalette(options: PaletteOptions): Palette {
  let open = false;
  let query = "";
  let index = 0;
  let listed: PaletteCommand[] = [];

  const filtered = () => {
    // filterCommands ranks by title/keywords; `run` is unused here.
    const commands = [
      ...buildPaletteCommands(options.context()),
      ...(options.extraCommands?.() ?? []),
    ];
    const byId = new Map(commands.map((command) => [command.id, command]));
    const asCommands: Command[] = commands.map((command) => ({ ...command, run: () => {} }));
    return filterCommands(asCommands, query).map((command) => byId.get(command.id)!);
  };

  const publish = () => {
    if (!open) {
      options.state.set("palette", CLOSED);
      return;
    }
    listed = filtered();
    index = listed.length === 0 ? 0 : Math.min(index, listed.length - 1);
    const viewport = options.viewport?.() ?? { width: 80, maxRows: 10 };
    options.state.set("palette", {
      open: true,
      query,
      commands: listed.map((command) => ({
        id: command.id,
        title: command.title,
        hint: command.hint ?? "",
        action: command.action,
      })),
      index,
      rows: paletteRows(
        listed,
        index,
        viewport.width,
        // The list's rows less the hint (ChatView's pickerContentRows - 1).
        Math.max(1, viewport.maxRows - 1),
      ),
    } satisfies TuiPaletteState);
  };

  const close = () => {
    if (!open) return;
    open = false;
    query = "";
    index = 0;
    if (options.mode() === "command") options.setMode("compose");
    publish();
  };

  const runAt = (at: number) => {
    const command = listed[at];
    close();
    if (command) options.run(command.action, command.payload);
  };

  publish();

  return {
    sync: () => {
      if (open) publish();
    },
    isOpen: () => open,
    dispatch: (action, payload) => {
      switch (action) {
        case "palette.open":
          // The shortcut toggles, like the web app's.
          if (open) close();
          else {
            open = true;
            query = "";
            index = 0;
            options.setMode("command");
            publish();
          }
          return true;
        case "palette.close":
          close();
          return true;
        case "palette.query.set": {
          const next = (payload as { query?: unknown } | undefined)?.query;
          query = typeof next === "string" ? next : "";
          index = 0;
          publish();
          return true;
        }
        case "palette.next":
        case "palette.previous": {
          if (listed.length === 0) return true;
          const delta = action === "palette.next" ? 1 : -1;
          index = (index + delta + listed.length) % listed.length;
          publish();
          return true;
        }
        case "palette.run": {
          if (!open) return true;
          // By row (a click), by id, or the highlighted command (Enter).
          const at = (payload as { index?: unknown } | undefined)?.index;
          const id = (payload as { id?: unknown } | undefined)?.id;
          const byId = typeof id === "string" ? listed.findIndex((entry) => entry.id === id) : -1;
          runAt(typeof at === "number" ? at : byId >= 0 ? byId : index);
          return true;
        }
        default:
          return false;
      }
    },
  };
}

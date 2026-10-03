// The workspace file browser (palette → Browse files), host side. Like
// FilesView.tsx it takes the conversation pane's place with the workspace as a
// tree, folders collapsed, and opens a file in the same pane. The listing and the open file live here; the
// FilesPanel and FileViewer bricks only paint `files` and dispatch `files.*`.
import type { ProjectEntry } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";
import { filetypeForPath } from "../diffSplit.ts";
import { buildFileTree, collectDirPaths, flattenFileTree, type FlatTreeRow } from "../fileTree.ts";
import { clip } from "../format.ts";
import { fileTypeColor } from "../icons.ts";
import { ansi, type Palette, THEME } from "../theme.ts";
import { chunk, markdownLines, plainText, styled, type StyledText } from "./styledText.ts";

const MARKDOWN_FILE = /\.(?:md|mdx|markdown)$/i;

/** Rows the panel's border and header take. */
export const FILES_CHROME_ROWS = 3;

export interface TuiFilesRow {
  readonly kind: "dir" | "file";
  readonly path: string;
  /** The row as drawn: selection marker, indent, folder or file glyph, name. */
  readonly text: string;
  /** The same row styled as FilesView draws it. */
  readonly line: StyledText;
  readonly selected: boolean;
}

export interface TuiFileViewerState {
  readonly path: string;
  readonly status: "loading" | "ready" | "error";
  /** What to show instead of contents: loading, the read error, or "(empty file)". */
  readonly message: string;
  /** Tree-sitter filetype, or "" for plain text. */
  readonly filetype: string;
  /** The visible lines, from `top`. */
  readonly text: string;
  readonly top: number;
  readonly lineCount: number;
  /** A Markdown file as rendered lines (the visible ones, from `top`); null shows `text` as source. */
  readonly rendered: ReadonlyArray<StyledText> | null;
}

/** Published under `files`. */
export interface TuiFilesState {
  readonly open: boolean;
  /** Opened to pick an image for the prompt: Enter on a file attaches it. */
  readonly attach: boolean;
  /** The workspace the browser lists. */
  readonly cwd: string;
  /** The header: `files · <cwd>` (or `file · <path>`) in accent, then the keys, dimmed. */
  readonly title: string;
  readonly hint: string;
  readonly status: "loading" | "ready" | "empty" | "error";
  /** The body line when there are no rows to show (loading, empty, error). */
  readonly message: string;
  /** The tree rows that fit, windowed around the selection. */
  readonly rows: ReadonlyArray<TuiFilesRow>;
  readonly viewer: TuiFileViewerState | null;
}

export interface FilesControllerOptions {
  readonly client: Pick<TuiClient, "listEntries" | "readFile">;
  /** The selected thread's workspace, or null without one. */
  readonly cwd: () => string | null;
  /** Size of the pane the browser replaces. */
  readonly height: () => number;
  readonly width: () => number;
  readonly palette?: Palette;
  readonly setOpen: (open: boolean) => void;
  readonly publish: (state: TuiFilesState) => void;
  /** Attach the picked workspace image to the prompt. */
  readonly attach?: (path: string) => void;
  /** The prompt can take another attachment (offers "Attach image"). */
  readonly canAttach?: () => boolean;
}

export interface FilesController {
  /** Handles a `files.*` action; false when it is not one. */
  readonly dispatch: (action: string, payload: unknown) => boolean;
  readonly close: () => void;
  readonly isOpen: () => boolean;
  /** Republish after a resize. */
  readonly sync: () => void;
  readonly commands: () => ReadonlyArray<{ readonly title: string; readonly action: string }>;
  readonly settled: () => Promise<void>;
}

const CLOSED: TuiFilesState = {
  open: false,
  attach: false,
  cwd: "",
  title: "",
  hint: "",
  status: "loading",
  message: "",
  rows: [],
  viewer: null,
};

function treeRows(entries: ReadonlyArray<ProjectEntry>) {
  // Folders come from the file paths; ignored entries (node_modules, build
  // output) are left out as the web's Files surface does.
  return buildFileTree(
    entries
      .filter((entry) => entry.kind === "file" && entry.ignored !== true)
      .map((entry) => ({ path: entry.path, additions: 0, deletions: 0 })),
  );
}

/** FilesView's tree row: marker and glyph, then the name clipped to `nameRoom`. */
function rowLine(row: FlatTreeRow, active: boolean, nameRoom: number, palette: Palette) {
  const marker = active ? "▸ " : "  ";
  const indent = "  ".repeat(row.depth);
  const bg = active ? { bg: palette.selectedBg } : {};
  const name = { fg: active ? palette.text : palette.dim, ...bg };
  if (row.kind === "dir") {
    return styled(
      chunk(`${marker}${indent}${row.collapsed ? "▸" : "▾"} `, {
        fg: active ? palette.accent : palette.dim,
        ...bg,
      }),
      chunk(clip(`${row.name}/`, nameRoom), name),
    );
  }
  const typeColor = fileTypeColor(row.path);
  return styled(
    chunk(`${marker}${indent}◦ `, {
      fg: typeColor ? ansi(typeColor) : active ? palette.bg : palette.faint,
      ...bg,
    }),
    chunk(clip(row.name, nameRoom), name),
  );
}

export function createFilesController(options: FilesControllerOptions): FilesController {
  const { client } = options;
  const palette = options.palette ?? THEME;
  let open = false;
  let attach = false;
  let cwd = "";
  let status: TuiFilesState["status"] = "loading";
  let tree: ReturnType<typeof buildFileTree> = [];
  let collapsed = new Set<string>();
  let selectedPath: string | null = null;
  let viewer: {
    path: string;
    status: TuiFileViewerState["status"];
    lines: string[];
    top: number;
    /** A Markdown file's rendered lines, at the pane's width. */
    rendered: StyledText[] | null;
  } | null = null;
  // Answers to an earlier open (or file) are dropped.
  let generation = 0;
  const inFlight = new Set<Promise<unknown>>();
  const track = (promise: Promise<unknown>) => {
    inFlight.add(promise);
    void promise.finally(() => inFlight.delete(promise));
  };

  const bodyRows = () => Math.max(1, options.height() - FILES_CHROME_ROWS);
  const flat = () => flattenFileTree(tree, collapsed);
  const selectedIndex = (rows: ReadonlyArray<FlatTreeRow>) =>
    Math.max(
      0,
      rows.findIndex((row) => row.path === selectedPath),
    );

  const publish = () => {
    if (!open) {
      options.publish(CLOSED);
      return;
    }
    const all = flat();
    const index = selectedIndex(all);
    const height = bodyRows();
    const start = Math.min(
      Math.max(0, index - Math.floor(height / 2)),
      Math.max(0, all.length - height),
    );
    const nameRoom = Math.max(8, options.width() - 18);
    const rows = all.slice(start, start + height).map((row, offset) => {
      const line = rowLine(row, start + offset === index, nameRoom, palette);
      return {
        kind: row.kind,
        path: row.path,
        text: plainText(line),
        line,
        selected: start + offset === index,
      };
    });
    const message =
      status === "loading"
        ? "loading…"
        : status === "error"
          ? "failed to list files"
          : status === "empty"
            ? "no files"
            : "";
    const shownLines = viewer?.rendered ?? viewer?.lines ?? [];
    options.publish({
      open,
      attach,
      cwd,
      title: viewer ? `file · ${clip(viewer.path, 40)}` : `files · ${clip(cwd, 40)}`,
      hint: viewer
        ? "  ·  PgUp/PgDn scroll · Esc back"
        : attach
          ? "  ·  ↑/↓ select · Enter attach · Esc close"
          : "  ·  ↑/↓ select · Enter open/expand · Esc close",
      status,
      message,
      rows,
      viewer: viewer && {
        path: viewer.path,
        status: viewer.status,
        message:
          viewer.status === "loading"
            ? "loading…"
            : viewer.status === "error"
              ? "failed to read file"
              : viewer.lines.length === 1 && viewer.lines[0] === ""
                ? "(empty file)"
                : "",
        filetype: filetypeForPath(viewer.path) ?? "",
        text: viewer.lines.slice(viewer.top, viewer.top + height).join("\n"),
        top: viewer.top,
        lineCount: shownLines.length,
        rendered: viewer.rendered?.slice(viewer.top, viewer.top + height) ?? null,
      },
    });
  };

  const openBrowser = (forAttach = false) => {
    const workspace = options.cwd();
    if (workspace === null) return;
    const token = ++generation;
    open = true;
    attach = forAttach;
    cwd = workspace;
    status = "loading";
    tree = [];
    collapsed = new Set();
    selectedPath = null;
    viewer = null;
    options.setOpen(true);
    publish();
    track(
      client.listEntries(workspace).then(
        (entries) => {
          if (token !== generation) return;
          tree = treeRows(entries);
          // Folders start collapsed: the workspace root first.
          collapsed = new Set(collectDirPaths(tree));
          status = tree.length === 0 ? "empty" : "ready";
          selectedPath = flat()[0]?.path ?? null;
          publish();
        },
        () => {
          if (token !== generation) return;
          status = "error";
          publish();
        },
      ),
    );
  };

  const close = () => {
    if (!open) return;
    generation += 1;
    open = false;
    attach = false;
    viewer = null;
    options.setOpen(false);
    publish();
  };

  const openFile = (path: string) => {
    const token = ++generation;
    viewer = { path, status: "loading", lines: [], top: 0, rendered: null };
    publish();
    track(
      client.readFile(cwd, path).then(
        (content) => {
          if (token !== generation || !viewer) return;
          if (content === null) viewer = { ...viewer, status: "error" };
          else {
            viewer = {
              ...viewer,
              status: "ready",
              lines: content.split("\n"),
              rendered: MARKDOWN_FILE.test(path)
                ? markdownLines(content, palette, Math.max(8, options.width() - 4))
                : null,
            };
          }
          publish();
        },
        () => {
          if (token !== generation || !viewer) return;
          viewer = { ...viewer, status: "error" };
          publish();
        },
      ),
    );
  };

  const scrollViewer = (delta: number) => {
    if (!viewer) return;
    const maxTop = Math.max(0, (viewer.rendered ?? viewer.lines).length - bodyRows());
    viewer = { ...viewer, top: Math.min(maxTop, Math.max(0, viewer.top + delta)) };
    publish();
  };

  const move = (delta: number) => {
    if (viewer) return scrollViewer(delta);
    const rows = flat();
    if (rows.length === 0) return;
    const index = Math.min(rows.length - 1, Math.max(0, selectedIndex(rows) + delta));
    selectedPath = rows[index]!.path;
    publish();
  };

  const toggleDir = (path: string) => {
    collapsed = new Set(collapsed);
    if (collapsed.has(path)) collapsed.delete(path);
    else collapsed.add(path);
  };

  const activate = () => {
    if (viewer) return;
    const row = flat()[selectedIndex(flat())];
    if (!row) return;
    if (row.kind === "dir") {
      toggleDir(row.path);
      publish();
    } else if (attach) {
      options.attach?.(row.path);
      close();
    } else openFile(row.path);
  };

  /** Left / Backspace: leave the folder the selection is in (the tree's ".."). */
  const up = () => {
    if (viewer) {
      viewer = null;
      publish();
      return;
    }
    const rows = flat();
    const index = selectedIndex(rows);
    const row = rows[index];
    if (!row) return;
    if (row.kind === "dir" && !row.collapsed) {
      toggleDir(row.path);
      publish();
      return;
    }
    // The nearest row above at a shallower depth is the containing folder.
    for (let i = index - 1; i >= 0; i -= 1) {
      const candidate = rows[i]!;
      if (candidate.kind === "dir" && candidate.depth < row.depth) {
        collapsed = new Set(collapsed).add(candidate.path);
        selectedPath = candidate.path;
        publish();
        return;
      }
    }
  };

  const back = () => {
    if (viewer) {
      generation += 1;
      viewer = null;
      publish();
    } else close();
  };

  const field = (payload: unknown, key: string) =>
    typeof payload === "object" && payload !== null
      ? (payload as Record<string, unknown>)[key]
      : undefined;

  options.publish(CLOSED);

  return {
    dispatch: (action, payload) => {
      switch (action) {
        case "files.open":
          openBrowser(field(payload, "attach") === true);
          return true;
        case "files.attach":
          openBrowser(true);
          return true;
        case "files.refresh":
          // List the workspace again (a file was added since the browser opened).
          if (open && !viewer) openBrowser(attach);
          return true;
        case "files.close":
          close();
          return true;
        case "files.move": {
          const delta = field(payload, "delta");
          if (open && typeof delta === "number") move(delta);
          return true;
        }
        case "files.page": {
          const delta = field(payload, "delta");
          if (open && typeof delta === "number") move(delta * Math.max(1, bodyRows() - 1));
          return true;
        }
        case "files.activate":
          if (open) activate();
          return true;
        case "files.up":
          if (open) up();
          return true;
        case "files.back":
          if (open) back();
          return true;
        case "files.select": {
          // A click: select the row, or open it when it is already selected.
          const path = field(payload, "path");
          if (!open || viewer || typeof path !== "string") return true;
          if (selectedPath === path) activate();
          else {
            selectedPath = path;
            publish();
          }
          return true;
        }
        default:
          return false;
      }
    },
    close,
    isOpen: () => open,
    sync: () => {
      if (open) publish();
    },
    commands: () =>
      options.cwd() === null
        ? []
        : [
            { title: "Browse files", action: "files.open" },
            ...(options.canAttach?.() ? [{ title: "Attach image", action: "files.attach" }] : []),
          ],
    settled: async () => {
      while (inFlight.size > 0) await Promise.all([...inFlight]);
    },
  };
}

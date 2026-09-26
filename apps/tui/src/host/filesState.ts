// The workspace file browser (palette → Browse files), host side. It replaces
// the conversation with the workspace as a tree, folders collapsed, and opens
// a file in the same pane. The listing and the open file live here; the
// FilesPanel and FileViewer bricks only paint `files` and dispatch `files.*`.
import type { ProjectEntry } from "@t3tools/contracts";

import type { TuiClient } from "../connection.ts";
import { filetypeForPath } from "../diffSplit.ts";
import { buildFileTree, collectDirPaths, flattenFileTree, type FlatTreeRow } from "../fileTree.ts";

/** The `layout.rightPanel.kind` the browser and viewer fill. */
export const FILES_PANEL = "files";

/** Rows the panel's border and header take. */
export const FILES_CHROME_ROWS = 3;

export interface TuiFilesRow {
  readonly kind: "dir" | "file";
  readonly path: string;
  /** The row as drawn: selection marker, indent, folder or file glyph, name. */
  readonly text: string;
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
}

/** Published under `files`. */
export interface TuiFilesState {
  readonly open: boolean;
  /** The workspace the browser lists, as shown in the header. */
  readonly cwd: string;
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
  /** Height of the pane the browser replaces. */
  readonly height: () => number;
  readonly setOpen: (open: boolean) => void;
  readonly publish: (state: TuiFilesState) => void;
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
  cwd: "",
  status: "loading",
  message: "",
  rows: [],
  viewer: null,
};

const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

function treeRows(entries: ReadonlyArray<ProjectEntry>) {
  // Folders come from the file paths; ignored entries (node_modules, build
  // output) are left out as the web's Files surface does.
  return buildFileTree(
    entries
      .filter((entry) => entry.kind === "file" && entry.ignored !== true)
      .map((entry) => ({ path: entry.path, additions: 0, deletions: 0 })),
  );
}

function rowText(row: FlatTreeRow, selected: boolean): string {
  const marker = selected ? "▸ " : "  ";
  const indent = "  ".repeat(row.depth);
  return row.kind === "dir"
    ? `${marker}${indent}${row.collapsed ? "▸" : "▾"} ${row.name}/`
    : `${marker}${indent}◦ ${row.name}`;
}

export function createFilesController(options: FilesControllerOptions): FilesController {
  const { client } = options;
  let open = false;
  let cwd = "";
  let status: TuiFilesState["status"] = "loading";
  let listError = "";
  let tree: ReturnType<typeof buildFileTree> = [];
  let collapsed = new Set<string>();
  let selectedPath: string | null = null;
  let viewer: {
    path: string;
    status: TuiFileViewerState["status"];
    error: string;
    lines: string[];
    top: number;
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
    const rows = all.slice(start, start + height).map((row, offset) => ({
      kind: row.kind,
      path: row.path,
      text: rowText(row, start + offset === index),
      selected: start + offset === index,
    }));
    const message =
      status === "loading"
        ? "loading…"
        : status === "error"
          ? `failed to list files: ${listError}`
          : status === "empty"
            ? "no files"
            : "";
    options.publish({
      open,
      cwd,
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
              ? `failed to read file: ${viewer.error}`
              : viewer.lines.length === 1 && viewer.lines[0] === ""
                ? "(empty file)"
                : "",
        filetype: filetypeForPath(viewer.path) ?? "",
        text: viewer.lines.slice(viewer.top, viewer.top + height).join("\n"),
        top: viewer.top,
        lineCount: viewer.lines.length,
      },
    });
  };

  const openBrowser = () => {
    const workspace = options.cwd();
    if (workspace === null) return;
    const token = ++generation;
    open = true;
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
        (error) => {
          if (token !== generation) return;
          status = "error";
          listError = errorText(error);
          publish();
        },
      ),
    );
  };

  const close = () => {
    if (!open) return;
    generation += 1;
    open = false;
    viewer = null;
    options.setOpen(false);
    publish();
  };

  const openFile = (path: string) => {
    const token = ++generation;
    viewer = { path, status: "loading", error: "", lines: [], top: 0 };
    publish();
    track(
      client.readFile(cwd, path).then(
        (content) => {
          if (token !== generation || !viewer) return;
          if (content === null) viewer = { ...viewer, status: "error", error: "not a text file" };
          else viewer = { ...viewer, status: "ready", lines: content.split("\n") };
          publish();
        },
        (error) => {
          if (token !== generation || !viewer) return;
          viewer = { ...viewer, status: "error", error: errorText(error) };
          publish();
        },
      ),
    );
  };

  const scrollViewer = (delta: number) => {
    if (!viewer) return;
    const maxTop = Math.max(0, viewer.lines.length - bodyRows());
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
          openBrowser();
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
      options.cwd() === null ? [] : [{ title: "Browse files", action: "files.open" }],
    settled: async () => {
      while (inFlight.size > 0) await Promise.all([...inFlight]);
    },
  };
}

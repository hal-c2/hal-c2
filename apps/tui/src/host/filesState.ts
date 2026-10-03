// The workspace file browser (palette → Browse files), host side. Like
// FilesView.tsx it takes the conversation pane's place with the workspace as a
// tree, folders collapsed, and opens a file in the same pane. The listing and the open file live here; the
// FilesPanel and FileViewer bricks only paint `files` and dispatch `files.*`.
import type { ProjectEntry } from "@hal-c2/contracts";

import type { TuiClient } from "../connection.ts";
import { EDITORS } from "@hal-c2/contracts";

import { filetypeForPath } from "../diffSplit.ts";
import { renderedFileKind, renderedFileMarkdown } from "../filePreview.ts";
import { buildFileTree, collectDirPaths, flattenFileTree, type FlatTreeRow } from "../fileTree.ts";
import { clip } from "../format.ts";
import { fileTypeColor } from "../icons.ts";
import { ansi, type Palette, THEME } from "../theme.ts";
import type { StatusKind } from "../store.ts";
import { chunk, markdownLines, plainText, styled, type StyledText } from "./styledText.ts";

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
  /** The file can be shown rendered (Markdown, delimited data, HTML) as well as its text. */
  readonly renderable: boolean;
  /** Showing the rendering (`lines`) rather than the text. */
  readonly rendered: boolean;
  /** The visible lines of the rendering, from `top`. */
  readonly lines: ReadonlyArray<StyledText>;
  /** The editor is open on the file (mode "fileEdit"); it holds `editText` when `editSeq` changes. */
  readonly editing: boolean;
  readonly editText: string;
  readonly editSeq: number;
  /** Whether the edit is on disk: "error" keeps the edit and says so. */
  readonly save: "saved" | "pending" | "error";
}

/** Published under `files`. */
export interface TuiFilesState {
  readonly open: boolean;
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
  readonly client: Pick<TuiClient, "listEntries" | "readFile"> &
    Partial<Pick<TuiClient, "mcCall" | "getServerConfig">>;
  /** The status row's message (saves, the editor that was opened). */
  readonly status?: (text: string, kind?: StatusKind) => void;
  /** The editor opened or closed: it has the keys while open. */
  readonly setEditing?: (editing: boolean) => void;
  /** The selected thread's workspace, or null without one. */
  readonly cwd: () => string | null;
  /** Size of the pane the browser replaces. */
  readonly height: () => number;
  readonly width: () => number;
  readonly palette?: Palette;
  readonly setOpen: (open: boolean) => void;
  readonly publish: (state: TuiFilesState) => void;
}

export interface FilesController {
  /** Handles a `files.*` action; false when it is not one. */
  readonly dispatch: (action: string, payload: unknown) => boolean;
  readonly close: () => void;
  readonly isOpen: () => boolean;
  /** The mode the open browser has the keys in. */
  readonly mode: () => "files" | "fileEdit";
  /** Republish after a resize. */
  readonly sync: () => void;
  readonly commands: () => ReadonlyArray<{
    readonly title: string;
    readonly action: string;
    readonly payload?: unknown;
  }>;
  readonly settled: () => Promise<void>;
}

const CLOSED: TuiFilesState = {
  open: false,
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
    /** Shown as its text although it could be rendered. */
    source?: boolean;
    /** The rendering, laid out to `renderedWidth`. */
    rendered?: StyledText[] | undefined;
    renderedWidth?: number;
    edit?: { text: string; seq: number; save: TuiFileViewerState["save"] } | undefined;
  } | null = null;
  let editSeq = 0;
  /** The inside of the viewer's frame. */
  const viewerWidth = () => Math.max(8, options.width() - 4);
  /** The lines the viewer shows: the rendering, or null for the file's text. */
  const renderedLines = (): StyledText[] | null => {
    if (!viewer || viewer.status !== "ready" || viewer.source || viewer.edit) return null;
    const kind = renderedFileKind(viewer.path);
    if (kind === null) return null;
    const width = viewerWidth();
    if (!viewer.rendered || viewer.renderedWidth !== width) {
      viewer.rendered = markdownLines(
        renderedFileMarkdown(viewer.path, kind, viewer.lines.join("\n")),
        palette,
        width,
      );
      viewer.renderedWidth = width;
    }
    return viewer.rendered;
  };
  // Answers to an earlier open (or file) are dropped.
  let generation = 0;
  // The same for the open file, so opening one never drops the listing under it.
  let viewGeneration = 0;
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
    const rendering = renderedLines();
    const renderable = viewer !== null && renderedFileKind(viewer.path) !== null;
    options.publish({
      open,
      cwd,
      title: viewer ? `file · ${clip(viewer.path, 40)}` : `files · ${clip(cwd, 40)}`,
      hint: viewer?.edit
        ? `  ·  ${viewer.edit.save === "error" ? "not saved" : viewer.edit.save === "pending" ? "saving…" : "saved"} · Esc done`
        : viewer
          ? // `i` (edit) and `o` (the environment's editor) are in the palette and the key reference.
            `  ·  PgUp/PgDn scroll · ${renderable ? `s ${rendering ? "source" : "rendered"} · ` : ""}Esc back`
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
        lineCount: rendering ? rendering.length : viewer.lines.length,
        renderable,
        rendered: rendering !== null,
        lines: rendering ? rendering.slice(viewer.top, viewer.top + height) : [],
        editing: viewer.edit !== undefined,
        editText: viewer.edit?.text ?? "",
        editSeq: viewer.edit?.seq ?? 0,
        save: viewer.edit?.save ?? "saved",
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
    loadEditors();
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
    viewGeneration += 1;
    open = false;
    if (viewer?.edit) save();
    viewer = null;
    options.setOpen(false);
    publish();
  };

  /** Open `path` in the viewer, on `line` (1-based) when given: as its text, that line on top. */
  const openFile = (path: string, line?: number) => {
    const token = ++viewGeneration;
    viewer = { path, status: "loading", lines: [], top: 0, ...(line ? { source: true } : {}) };
    publish();
    track(
      client.readFile(cwd, path).then(
        (content) => {
          if (token !== viewGeneration || !viewer) return;
          if (content === null) viewer = { ...viewer, status: "error" };
          else {
            const lines = content.split("\n");
            const top = line ? Math.min(Math.max(0, line - 1), Math.max(0, lines.length - 1)) : 0;
            viewer = { ...viewer, status: "ready", lines, top };
          }
          publish();
        },
        () => {
          if (token !== viewGeneration || !viewer) return;
          viewer = { ...viewer, status: "error" };
          publish();
        },
      ),
    );
  };

  const scrollViewer = (delta: number) => {
    if (!viewer) return;
    const maxTop = Math.max(0, (renderedLines() ?? viewer.lines).length - bodyRows());
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

  const errorText = (error: unknown) => (error instanceof Error ? error.message : String(error));

  /** Write the edit; the answer to an older save never marks a newer edit as saved. */
  const save = () => {
    const edit = viewer?.edit;
    if (!viewer || !edit || edit.save === "saved") return;
    const { path } = viewer;
    const text = edit.text;
    const call = client.mcCall
      ? client.mcCall("projects.writeFile", { cwd, relativePath: path, contents: text })
      : Promise.reject(new Error("This server cannot write files."));
    track(
      call.then(
        () => {
          if (viewer?.path !== path || !viewer.edit) return;
          // What was written is the file now, whether or not more was typed since.
          viewer.lines = text.split("\n");
          viewer.rendered = undefined;
          if (viewer.edit.text === text) {
            viewer.edit.save = "saved";
            options.status?.(`Saved ${path}.`, "success");
          }
          publish();
        },
        (error: unknown) => {
          if (viewer?.path !== path || !viewer.edit) return;
          viewer.edit.save = "error";
          options.status?.(`Could not save ${path}: ${errorText(error)}`, "error");
          publish();
        },
      ),
    );
  };

  const startEdit = () => {
    if (!viewer || viewer.status !== "ready" || viewer.edit) return;
    viewer.edit = { text: viewer.lines.join("\n"), seq: ++editSeq, save: "saved" };
    options.setEditing?.(true);
    publish();
  };

  /** Esc in the editor: what is not saved yet is written first. */
  const finishEdit = () => {
    if (!viewer?.edit) return;
    const failed = viewer.edit.save === "error";
    save();
    // A failed save keeps the editor open with the edit in it.
    if (failed) return;
    viewer.lines = viewer.edit.text.split("\n");
    viewer.rendered = undefined;
    viewer.edit = undefined;
    options.setEditing?.(false);
    publish();
  };

  /** The editors the environment can launch, by `EDITORS` id and label. */
  let editors: ReadonlyArray<{ readonly id: string; readonly label: string }> = [];
  const loadEditors = () => {
    if (!client.getServerConfig) return;
    track(
      client.getServerConfig().then(
        (config) => {
          editors = (config.availableEditors ?? []).flatMap((id) => {
            const known = EDITORS.find((editor) => editor.id === id);
            return known && known.id !== "file-manager" ? [{ id, label: known.label }] : [];
          });
        },
        () => {},
      ),
    );
  };

  const openInEditor = (editorId: string | undefined) => {
    if (!viewer) return;
    const editor = editors.find((candidate) => candidate.id === editorId) ?? editors[0];
    if (!editor || !client.mcCall) {
      options.status?.("The environment has no editor to open files in.", "error");
      return;
    }
    const { path } = viewer;
    track(
      client.mcCall("shell.openInEditor", { cwd: `${cwd}/${path}`, editor: editor.id }).then(
        () => options.status?.(`Opened ${path} in ${editor.label}.`, "success"),
        (error: unknown) =>
          options.status?.(
            `Could not open ${path} in ${editor.label}: ${errorText(error)}`,
            "error",
          ),
      ),
    );
  };

  const back = () => {
    if (viewer) {
      viewGeneration += 1;
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
        case "files.view": {
          // A file named from elsewhere (a search match): the browser opens on it.
          const path = field(payload, "path");
          const line = field(payload, "line");
          if (typeof path !== "string") return true;
          if (!open) openBrowser();
          if (!open) return false;
          selectedPath = path;
          openFile(path, typeof line === "number" ? line : undefined);
          return true;
        }
        case "files.viewer.toggleSource":
          if (!viewer || viewer.edit || renderedFileKind(viewer.path) === null) return true;
          viewer = { ...viewer, source: !viewer.source, top: 0 };
          publish();
          return true;
        case "files.edit":
          if (open) startEdit();
          return true;
        case "files.edit.set": {
          const text = field(payload, "text");
          if (!viewer?.edit || typeof text !== "string" || text === viewer.edit.text) return true;
          viewer.edit.text = text;
          viewer.edit.save = "pending";
          publish();
          return true;
        }
        case "files.edit.save":
          save();
          return true;
        case "files.edit.done":
          finishEdit();
          return true;
        case "files.openInEditor": {
          const editor = field(payload, "editor");
          if (open) openInEditor(typeof editor === "string" ? editor : undefined);
          return true;
        }
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
    mode: () => (viewer?.edit ? "fileEdit" : "files"),
    sync: () => {
      if (open) publish();
    },
    commands: () =>
      options.cwd() === null
        ? []
        : [
            { title: "Browse files", action: "files.open" },
            ...(viewer && !viewer.edit
              ? [
                  ...(renderedFileKind(viewer.path) === null
                    ? []
                    : [
                        {
                          title: viewer.source ? "Show file rendered" : "Show file source",
                          action: "files.viewer.toggleSource",
                        },
                      ]),
                  { title: "Edit file", action: "files.edit" },
                  ...editors.map((editor) => ({
                    title: `Open file in ${editor.label}`,
                    action: "files.openInEditor",
                    payload: { editor: editor.id },
                  })),
                ]
              : []),
          ],
    settled: async () => {
      while (inFlight.size > 0) await Promise.all([...inFlight]);
    },
  };
}

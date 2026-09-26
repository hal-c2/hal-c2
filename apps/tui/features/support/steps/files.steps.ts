// File browser steps (tui/files.feature, files/file-explorer.feature,
// files/file-viewer-and-editing.feature). The fake client lists `ctx.files`
// (plus ignored entries) for the thread's workspace and reads their contents;
// steps drive the browser with keys and assert on the frame and `files` key.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import type { TuiFilesState } from "../../../src/host/filesState.ts";
import { threadKey } from "../../../src/host/sidebarState.ts";
import type { Environment } from "../environment.ts";
import { project, shell } from "../fakeClient.ts";
import { chooseCommand } from "../threadUi.ts";
import { openRevertPicker } from "./timeline.steps.ts";
import { boot, findObject, pressKey, settle, useClient, type World } from "../world.ts";

interface FilesWorld extends World {
  /** Workspace files and their contents, by forward-slash path. */
  files?: Record<string, string>;
  /** Extra listing entries (ignored folders, backslash paths). */
  extraEntries?: Array<{ path: string; kind: "file" | "directory"; ignored?: boolean }>;
  /** Replaces the listing's paths (e.g. with backslash separators). */
  listedPaths?: string[];
  listError?: string;
  readErrors?: Record<string, string>;
}

const LONG_FILE = Array.from(
  { length: 80 },
  (_, index) => `export const line${index + 1}: number = ${index + 1};`,
).join("\n");

const DEFAULT_FILES = (): Record<string, string> => ({
  "src/app.ts": LONG_FILE,
  "src/lib/cart.ts": "export function cartTotal(items: number[]) {\n  return items.length;\n}\n",
  "README.md": "# shop\n",
});

/**
 * Boot on the project's thread, with the fake serving `ctx.files`. The
 * Background's project (T1's environment.ts) names it; the workspace path is
 * the scenario's.
 */
async function openOnWorkspace(ctx: FilesWorld, workspaceRoot: string, name = "shop") {
  if (ctx.app) return;
  ctx.files ??= DEFAULT_FILES();
  const environment = (ctx as { env?: Environment }).env;
  const title = environment?.projects[0]?.title ?? name;
  const projects = [{ ...project, title, workspaceRoot }];
  useClient(ctx, {
    shellSnapshot: shell(undefined, projects as never),
    listEntries: async () => {
      if (ctx.listError) throw new Error(ctx.listError);
      const paths = ctx.listedPaths ?? Object.keys(ctx.files!);
      return [
        ...paths.map((path) => ({ path, kind: "file" as const })),
        ...(ctx.extraEntries ?? []),
      ] as never;
    },
    readFile: async (_cwd, path) => {
      const error = ctx.readErrors?.[path];
      if (error) throw new Error(error);
      return ctx.files![path] ?? null;
    },
  });
  await boot(ctx);
  ctx.fake!.connect();
  // This client serves the Background's environment: `ui` must not replace its shell.
  if (environment) environment.connected = true;
  ctx.host!.dispatch("thread.open", { key: threadKey("t1") });
  await settle(ctx);
}

const ensureOpen = (ctx: FilesWorld) => openOnWorkspace(ctx, "/home/sam/shop");
const files = (ctx: World) => ctx.host!.state.get("files") as TuiFilesState;
const rowLabels = (ctx: World) => files(ctx).rows.map((row) => row.text.slice(2).trim());
const selected = (ctx: World) => files(ctx).rows.find((row) => row.selected)?.path;

async function browse(ctx: FilesWorld) {
  await ensureOpen(ctx);
  await chooseCommand(ctx, "Browse files");
  await settle(ctx);
}

/** Move the selection to `path` with the arrow keys. */
async function selectRow(ctx: World, path: string) {
  for (let guard = 0; guard < 200 && selected(ctx) !== path; guard += 1) {
    const rows = files(ctx).rows.map((row) => row.path);
    const target = rows.indexOf(path);
    const current = rows.indexOf(selected(ctx) ?? "");
    await pressKey(ctx, target >= 0 && target < current ? "Up" : "Down");
  }
  expect(selected(ctx)).toBe(path);
}

/** Open a file from the tree: expand each folder on its path, then Enter on it. */
async function openFile(ctx: FilesWorld, path: string) {
  if (!files(ctx)?.open) await browse(ctx);
  const segments = path.split("/");
  for (let depth = 1; depth < segments.length; depth += 1) {
    const folder = segments.slice(0, depth).join("/");
    const row = files(ctx).rows.find((candidate) => candidate.path === folder);
    if (!row) continue; // compacted into a deeper folder row
    await selectRow(ctx, folder);
    if (row.text.includes("▸ " + segments[depth - 1])) await pressKey(ctx, "Enter");
  }
  await selectRow(ctx, path);
  await pressKey(ctx, "Enter");
  await settle(ctx);
}

// --- Setup -----------------------------------------------------------------------

step(
  "the terminal client is open on a thread whose workspace is {string}",
  (ctx: FilesWorld, workspace: string) => openOnWorkspace(ctx, workspace),
);
step("{string} holds the text file {string}", (ctx: FilesWorld, _name: string, path: string) => {
  ctx.files = { ...(ctx.files ?? DEFAULT_FILES()), [path]: ctx.files?.[path] ?? LONG_FILE };
});
step(
  /^"([^"]+)" holds ((?:"[^"]+", )*"[^"]+") and an ignored "([^"]+)" folder$/,
  async (ctx: FilesWorld, name: string, list: string, ignored: string) => {
    ctx.files = Object.fromEntries(
      [...list.matchAll(/"([^"]+)"/g)].map((match) => [match[1]!, `// ${match[1]}\n`]),
    );
    ctx.extraEntries = [{ path: `${ignored}/left-pad/index.js`, kind: "file", ignored: true }];
    await openOnWorkspace(ctx, `/home/sam/${name}`, name);
  },
);

step("the workspace has no files", (ctx: FilesWorld) => {
  ctx.files = {};
});
step("the workspace cannot be listed", (ctx: FilesWorld) => {
  ctx.listError = "permission denied";
});
step("the environment cannot list {string}", (ctx: FilesWorld) => {
  ctx.listError = "permission denied";
});
step("{string} cannot be read", (ctx: FilesWorld, path: string) => {
  ctx.files = { ...(ctx.files ?? DEFAULT_FILES()), [path]: "" };
  (ctx.readErrors ??= {})[path] = "not a text file";
});
step("reading {string} fails", (ctx: FilesWorld, path: string) => {
  ctx.files ??= DEFAULT_FILES();
  (ctx.readErrors ??= {})[path] = "permission denied";
});
step("{string} in {string} is empty", (ctx: FilesWorld, path: string) => {
  ctx.files = { ...(ctx.files ?? DEFAULT_FILES()), [path]: "" };
});

// --- Browsing ----------------------------------------------------------------------

step("the file browser is open", browse);
step("the user is browsing files", browse);
step("the user browses files", browse);

step("the workspace name is shown above a tree of folders and files", async (ctx: World) => {
  const lines = (await settle(ctx)).split("\n");
  const header = lines.findIndex((line) => line.includes("files · ~/code/shop"));
  const folder = lines.findIndex((line) => line.includes("▸ src/"));
  const file = lines.findIndex((line) => line.includes("◦ README.md"));
  expect(header).toBeGreaterThanOrEqual(0);
  expect(folder).toBe(header + 1);
  expect(file).toBe(header + 2);
  expect(ctx.host!.state.get("mode")).toBe("files");
});

step(
  "the user moves to the folder {string} and presses {string}",
  async (ctx: World, folder: string, key: string) => {
    await selectRow(ctx, folder);
    await pressKey(ctx, key);
    await settle(ctx);
  },
);
step("the files inside {string} are listed", (ctx: World, folder: string) => {
  expect(rowLabels(ctx)).toEqual(["▾ src/", "▸ lib/", "◦ app.ts", "◦ README.md"]);
  expect(
    files(ctx)
      .rows.slice(1, 3)
      .map((row) => row.path),
  ).toEqual([`${folder}/lib`, `${folder}/app.ts`]);
});

step("the file browser is inside {string}", async (ctx: FilesWorld, folder: string) => {
  await browse(ctx);
  await selectRow(ctx, folder);
  await pressKey(ctx, "Enter");
  await pressKey(ctx, "Down");
  expect(selected(ctx)?.startsWith(`${folder}/`)).toBe(true);
});
// The tree's ".." is Backspace (or Left): it leaves the folder the selection is in.
step("the user goes up to {string}", async (ctx: World) => {
  await pressKey(ctx, "Backspace");
  await settle(ctx);
});
step("the workspace root is listed again", (ctx: World) => {
  expect(rowLabels(ctx)).toEqual(["▸ src/", "◦ README.md"]);
  expect(selected(ctx)).toBe("src");
});

step("folders are listed before files", (ctx: World) => {
  expect(rowLabels(ctx)).toEqual(["▸ src/", "◦ README.md"]);
  expect(rowLabels(ctx).join()).not.toContain("node_modules");
});
step("each folder can be expanded and collapsed", async (ctx: World) => {
  await selectRow(ctx, "src");
  await pressKey(ctx, "Enter");
  expect(rowLabels(ctx)).toEqual(["▾ src/", "▸ lib/", "◦ app.ts", "◦ README.md"]);
  await selectRow(ctx, "src/lib");
  await pressKey(ctx, "Enter");
  expect(await settle(ctx)).toContain("◦ cart.ts");
  await selectRow(ctx, "src");
  await pressKey(ctx, "Enter");
  const frame = await settle(ctx);
  expect(rowLabels(ctx)).toEqual(["▸ src/", "◦ README.md"]);
  expect(frame).not.toContain("app.ts");
});

step("the user closes the file browser", async (ctx: World) => {
  await pressKey(ctx, "Esc");
  await settle(ctx);
});
// "the conversation is shown again" (timeline.steps.ts) checks the browser closed.
async function conversationShown(ctx: World) {
  const frame = await settle(ctx);
  expect(files(ctx).open).toBe(false);
  expect(ctx.host!.state.get("mode")).toBe("compose");
  expect(findObject(ctx, "conversation").get("visible")).toBe(true);
  expect(frame).not.toContain("files · ");
}

step("the browser says there are no files", async (ctx: World) => {
  expect(await settle(ctx)).toContain("no files");
  expect(files(ctx).status).toBe("empty");
  expect(files(ctx).rows.length).toBe(0);
});
async function listingFailed(ctx: World) {
  expect(await settle(ctx)).toContain("failed to list files: permission denied");
  expect(files(ctx).status).toBe("error");
}
step("the browser shows the error", listingFailed);
step("the user is told the files could not be listed", listingFailed);

step("the workspace listing uses backslash separators", async (ctx: FilesWorld) => {
  ctx.listedPaths = ["src\\app.ts", "src\\lib\\cart.ts", "README.md", "src/index.ts"];
  await browse(ctx);
});
step("the tree groups them into the same folders as forward slashes", async (ctx: World) => {
  await selectRow(ctx, "src");
  await pressKey(ctx, "Enter");
  await selectRow(ctx, "src/lib");
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(files(ctx).rows.map((row) => row.path)).toEqual([
    "src",
    "src/lib",
    "src/lib/cart.ts",
    "src/app.ts",
    "src/index.ts",
    "README.md",
  ]);
});

// --- Opening files -----------------------------------------------------------------

// One step for every "the user opens …": the revert picker by its palette title, else a file.
step("the user opens {string}", (ctx: FilesWorld, label: string) =>
  label === "Revert to checkpoint…" ? openRevertPicker(ctx) : openFile(ctx, label),
);
step("the user browses files and opens {string}", async (ctx: FilesWorld, path: string) => {
  await browse(ctx);
  await openFile(ctx, path);
});
step("the user is reading {string} in the file browser", openFile);

async function shownWithColouring(ctx: World, path: string) {
  const lines = (await settle(ctx)).split("\n");
  const header = lines.findIndex((line) => line.includes(`file · ${path}`));
  expect(header).toBeGreaterThanOrEqual(0);
  expect(lines[header + 1]).toContain("export const line1: number = 1;");
  expect(files(ctx).viewer).toMatchObject({ path, status: "ready", filetype: "typescript" });
  expect(findObject(ctx, "fileViewerCode").get("filetype")).toBe("typescript");
}
step("the file's name is shown above its contents", (ctx: World) =>
  shownWithColouring(ctx, "src/app.ts"),
);
step("the contents are highlighted as TypeScript", (ctx: World) => {
  expect(findObject(ctx, "fileViewerCode").get("filetype")).toBe("typescript");
});
step("the contents of {string} are shown with syntax colouring", shownWithColouring);

step("the user can scroll through the file and go back to the tree", async (ctx: World) => {
  await pressKey(ctx, "PgDn");
  const frame = await settle(ctx);
  expect(files(ctx).viewer!.top).toBeGreaterThan(0);
  expect(frame).not.toContain("line1: number");
  expect(frame).toContain(`line${files(ctx).viewer!.top + 1}: number`);
  await pressKey(ctx, "Esc");
  expect(await settle(ctx)).toContain("files · /home/sam/shop");
  expect(files(ctx).viewer).toBeNull();
});

step("the tree is shown again", async (ctx: World) => {
  const frame = await settle(ctx);
  expect(files(ctx)).toMatchObject({ open: true, viewer: null });
  expect(frame).toContain("◦ app.ts");
});
step("pressing {string} once more returns to the conversation", async (ctx: World, key: string) => {
  await pressKey(ctx, key);
  await conversationShown(ctx);
});

step("the browser shows the read error", async (ctx: World) => {
  expect(await settle(ctx)).toContain("failed to read file: not a text file");
});
step("the user is told the file could not be read", async (ctx: World) => {
  expect(await settle(ctx)).toContain("failed to read file: permission denied");
});
step("the user is told the file is empty", async (ctx: World) => {
  expect(await settle(ctx)).toContain("(empty file)");
});

// --- Attach image ---------------------------------------------------------------------

// The composer (and its attachments) is not on the host yet, and the TUI does
// not offer "Attach image" at all until the attach flow lands (@backlog), so
// this only holds the palette to not offering it.
step("the prompt already has the most attachments a turn allows", ensureOpen);
// "the user opens the command palette" (threads.steps.ts) opens it and
// "{string} is not offered" (projects.steps.ts) checks its commands.

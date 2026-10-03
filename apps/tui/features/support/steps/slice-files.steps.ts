// tui/files.feature: attaching an image from the browser, Markdown files
// rendered in the viewer, and a workspace file in the user's $EDITOR (with the
// conflict check when it changed on disk meanwhile).
import { editInPlace } from "./files-viewer.steps.ts";
import { expect } from "bun:test";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import { PROVIDER_SEND_TURN_MAX_ATTACHMENTS } from "@hal-c2/contracts";

import type { TuiComposerState, TuiSelectState } from "../../../src/host/composerState.ts";
import type { TuiFilesState } from "../../../src/host/filesState.ts";
import type { EditorCommand } from "../../../src/promptEditor.ts";
import { THEME } from "../../../src/theme.ts";
import { step } from "../../steps.ts";
import { expectColour, objectRows, rectOf, textWithin } from "../design.ts";
import { deferred } from "../threadWorld.ts";
import { pressKey, settle, type World } from "../world.ts";
import { PNG } from "./composer.steps.ts";
import { ensureOpen, openFile, selectRow, type FilesWorld } from "./files.steps.ts";

interface EditorRun {
  readonly command: EditorCommand;
  readonly file: string;
  /** What the editor was given to edit. */
  readonly content: string;
}

interface SliceFilesWorld extends FilesWorld {
  editorRuns?: EditorRun[];
  /** What the editor leaves in the file when it exits; undefined leaves it unchanged. */
  editorWrites?: string;
  /** Resolved when the user "saves and quits" a held editor. */
  editorHold?: ReturnType<typeof deferred>;
}

const files = (ctx: World) => ctx.host!.state.get("files") as TuiFilesState;
const composer = (ctx: World) => ctx.host!.state.get("composer") as TuiComposerState;
const select = (ctx: World) => ctx.host!.state.get("select") as TuiSelectState;
const status = (ctx: World) => ctx.host!.state.get("status") as { text: string; kind: string };
const writes = (ctx: World) => ctx.fake!.calls.filter((call) => call.method === "writeFile");

/** A stand-in for `$EDITOR`: records what it was run on, then writes and exits (or waits). */
function useEditor(ctx: SliceFilesWorld) {
  const runs: EditorRun[] = (ctx.editorRuns ??= []);
  ctx.runEditor = async (command, file) => {
    const path = file.replace(/:\d+$/, "");
    runs.push({ command, file, content: NodeFS.readFileSync(path, "utf8") });
    if (ctx.editorHold) await ctx.editorHold.promise;
    if (ctx.editorWrites !== undefined) NodeFS.writeFileSync(path, ctx.editorWrites);
  };
}

// --- Attach image ---------------------------------------------------------------

step("the prompt already has the most attachments a turn allows", async (ctx: FilesWorld) => {
  await ensureOpen(ctx);
  for (let i = 0; i < PROVIDER_SEND_TURN_MAX_ATTACHMENTS; i += 1) {
    ctx.fake!.workspaceFiles.set(`shots/${i}.png`, PNG);
    ctx.host!.dispatch("composer.attach", { path: `shots/${i}.png` });
  }
  await settle(ctx);
  expect(composer(ctx).attachments).toHaveLength(PROVIDER_SEND_TURN_MAX_ATTACHMENTS);
});

step("the file browser opens and says Enter attaches the selection", async (ctx: FilesWorld) => {
  await settle(ctx);
  expect(files(ctx)).toMatchObject({ open: true, attach: true });
  expect(ctx.host!.state.get("mode")).toBe("files");
  const [header] = await objectRows(ctx, "filesPanel");
  expect((await objectRows(ctx, "filesPanel")).join("\n")).toContain("Enter attach");
  expect(header).toBeDefined();
});

step("choosing {string} attaches it to the prompt", async (ctx: FilesWorld, path: string) => {
  // The image lands in the workspace while the browser is open; "r" lists it again.
  ctx.extraEntries = [...(ctx.extraEntries ?? []), { path, kind: "file" }];
  ctx.fake!.workspaceFiles.set(path, PNG);
  await pressKey(ctx, "r");
  await settle(ctx);
  expect(files(ctx)).toMatchObject({ open: true, attach: true });
  const folder = NodePath.posix.dirname(path);
  await selectRow(ctx, folder);
  await pressKey(ctx, "Enter");
  await selectRow(ctx, path);
  await pressKey(ctx, "Enter");
  await settle(ctx);
  // The browser closed and the prompt holds the image, read from the workspace.
  expect(files(ctx).open).toBe(false);
  expect(ctx.host!.state.get("mode")).toBe("compose");
  expect(composer(ctx).attachments.map((attachment) => attachment.id)).toEqual([path]);
  expect(ctx.fake!.calls.filter((call) => call.method === "readFileBase64")).toHaveLength(1);
  expect((await objectRows(ctx, "composerAttachments")).join("\n")).toContain(
    NodePath.posix.basename(path),
  );
});

// --- Markdown ---------------------------------------------------------------------

const README = [
  "# Shop",
  "",
  "The **storefront** and its `cart` service.",
  "",
  "- run `bun dev`",
  "- read the [docs](https://example.com/docs)",
].join("\n");

step("the user opens {string} in the file browser", async (ctx: FilesWorld, path: string) => {
  ctx.files = { ...ctx.files, "src/app.ts": "export {};\n", [path]: README };
  await openFile(ctx, path);
});

step("it is shown as rendered Markdown", async (ctx: World) => {
  await settle(ctx);
  const viewer = files(ctx).viewer!;
  expect(viewer).toMatchObject({ path: "README.md", status: "ready" });
  expect(viewer.rendered).not.toBeNull();
  const inner = rectOf(ctx, "fileViewerRendered");
  const rows = (await objectRows(ctx, "fileViewerRendered")).map((row) => row.trimEnd());
  // The markup is gone: a heading without its "#", emphasis without its stars.
  expect(rows).toContain("Shop");
  expect(rows).toContain("The storefront and its cart service.");
  expect(rows.join("\n")).not.toContain("**");
  expect(rows.join("\n")).not.toContain("# Shop");
  // And it is styled: the heading in the accent colour, strong text bold.
  expectColour((await textWithin(ctx, inner, "Shop")).span.fg, THEME.accent);
  const strong = await textWithin(ctx, inner, "storefront");
  expect(strong.span.attributes & 1).toBe(1);
});

// --- $EDITOR ------------------------------------------------------------------------

step("the user opens {string} in their editor", async (ctx: SliceFilesWorld, path: string) => {
  useEditor(ctx);
  await openFile(ctx, path);
  await pressKey(ctx, "PgDn");
  await pressKey(ctx, "e");
  await settle(ctx);
});

step("the file opens in the user's editor", async (ctx: SliceFilesWorld) => {
  expect(ctx.editorRuns).toHaveLength(1);
  const [run] = ctx.editorRuns!;
  // The user's editor, on a copy of the workspace file, at the line they were reading.
  expect(run!.command.cmd).toBe("nvim");
  expect(NodePath.basename(run!.file)).toBe("app.ts");
  expect(run!.content).toBe(ctx.files!["src/app.ts"]!);
  const top = files(ctx).viewer!.top;
  expect(top).toBeGreaterThan(0);
  expect(run!.command.args).toEqual([`+${top + 1}`]);
  // Nothing was changed, so nothing is written back.
  expect(writes(ctx)).toEqual([]);
  expect(status(ctx).text).toBe("No changes to src/app.ts.");
});

// The shared files/ scenarios (also the desktop's) edit in the viewer, saving as the typing
// pauses; tui/files.feature edits a copy in $EDITOR and writes it back on exit.
step("the user is editing {string}", async (ctx: SliceFilesWorld, path: string) => {
  if (ctx.tags.includes("@desktop")) return editInPlace(ctx, path);
  useEditor(ctx);
  ctx.editorHold = deferred();
  ctx.held = (ctx.held ?? 0) + 1;
  await openFile(ctx, path);
  await pressKey(ctx, "e");
  await settle(ctx);
  expect(ctx.editorRuns).toHaveLength(1);
  expect(status(ctx).text).toBe(`Editing ${path} in $EDITOR…`);
});

step("the file changed on disk since it was opened", (ctx: SliceFilesWorld) => {
  ctx.files = {
    ...ctx.files,
    "src/app.ts": `${ctx.files!["src/app.ts"]}\n// from another agent\n`,
  };
});

step("the user saves", async (ctx: SliceFilesWorld) => {
  ctx.editorWrites = "export const mine = true;\n";
  ctx.held = (ctx.held ?? 1) - 1;
  ctx.editorHold!.resolve(undefined);
  await settle(ctx);
});

step("the client warns about the conflict instead of overwriting", async (ctx: SliceFilesWorld) => {
  expect(status(ctx)).toEqual({
    kind: "error",
    text: "src/app.ts changed on disk while you edited it; nothing was overwritten.",
  });
  expect(writes(ctx)).toEqual([]);
  expect(select(ctx)).toMatchObject({ open: true, title: "conflict · src/app.ts" });
  expect(select(ctx).options.map((option) => option.label)).toEqual([
    "Keep the file on disk",
    "Overwrite with my edit",
    "Copy my edit",
  ]);
  expect((await objectRows(ctx, "selectOverlay")).join("\n")).toContain("Overwrite with my edit");
  // Keeping the file on disk is the default answer; nothing is written.
  await pressKey(ctx, "Enter");
  await settle(ctx);
  expect(writes(ctx)).toEqual([]);
  expect(status(ctx).text).toBe("Kept src/app.ts as it is on disk.");
});

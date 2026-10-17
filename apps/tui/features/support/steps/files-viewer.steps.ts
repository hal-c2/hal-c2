// The file viewer beyond reading (files/file-viewer-and-editing.feature):
// rendered files and their source, opening a file in an editor on this computer,
// and editing with saves that follow the typing.
import { expect } from "bun:test";
import { DEFAULT_SERVER_SETTINGS, EDITORS } from "@hal-c2/contracts";

import type { TuiFilesState } from "../../../src/host/filesState.ts";
import { FILES_ELSEWHERE, hostedHere } from "../../../src/thisMachine.ts";
import { step } from "../../steps.ts";
import { PREVIEW_FILES } from "../filePreviewFixtures.ts";
import { chooseCommand } from "../threadUi.ts";
import { advance, findObject, pressKey, settle, typeText, type World } from "../world.ts";
import { openFile } from "./files.steps.ts";

interface ViewerWorld extends World {
  /** The MC's reason for refusing to write a path. */
  writeErrors?: Record<string, string>;
  /** What the editor held before the scenario typed into it. */
  original?: string;
}

const CHANGE = "// tuned ";
const WORKSPACE = "/home/sam/shop";
const files = (ctx: World) => ctx.host!.state.get("files") as TuiFilesState;
const viewer = (ctx: World) => files(ctx).viewer!;
export const status = (ctx: World) =>
  ctx.host!.state.get("status") as { kind: string; text: string };
export const statusLabel = (ctx: World) =>
  (ctx.host!.state.get("statusRow") as { label: string }).label;
export const mcCalls = (ctx: World, method: string) =>
  ctx.fake!.settings.callsTo(method).map((call) => call.payload as Record<string, unknown>);
const editorText = (ctx: World) => String(findObject(ctx, "fileEditor").get("text") ?? "");

/** Run `setup` on the fake client the files steps make, right before the client starts. */
export const beforeBoot = (ctx: World, setup: () => void) => {
  const previous = ctx.prepare;
  ctx.prepare = () => {
    previous?.();
    setup();
  };
};

/** The MC writes files, refusing the paths the scenario says it cannot. */
const servesWrites = (ctx: ViewerWorld) => {
  ctx.fake!.override("writeFile", async (cwd, relativePath, contents) => {
    const refusal = ctx.writeErrors?.[relativePath];
    if (refusal) throw new Error(refusal);
    ctx.fake!.server.written.set(`${cwd}:${relativePath}`, contents);
  });
};
/** The writes the client asked for, as `{ cwd, relativePath, contents }`. */
const writes = (ctx: World) =>
  ctx
    .fake!.calls.filter((call) => call.method === "writeFile")
    .map((call) => {
      const [cwd, relativePath, contents] = call.args as [string, string, string];
      return { cwd, relativePath, contents };
    });

// --- Rendered and source -----------------------------------------------------------

async function expectShown(ctx: World, rendered: boolean) {
  const screen = await settle(ctx);
  const file = viewer(ctx);
  const preview = PREVIEW_FILES[file.path]!;
  expect(file).toMatchObject({ status: "ready", renderable: true });
  expect(file.rendered !== null).toBe(rendered);
  for (const text of rendered ? preview.rendered : preview.source) expect(screen).toContain(text);
  for (const text of rendered ? preview.source : preview.rendered.slice(0, 0)) {
    expect(screen).not.toContain(text);
  }
  expect(findObject(ctx, "fileViewerCode").get("visible")).toBe(!rendered);
}

step("the file is shown rendered", (ctx: World) => expectShown(ctx, true));
step("the file's text is shown", (ctx: World) => expectShown(ctx, false));
step("the user switches to the source", async (ctx: World) => {
  await pressKey(ctx, "s");
});
step("the user switches back", async (ctx: World) => {
  await pressKey(ctx, "s");
});

// --- The environment's editor ---------------------------------------------------------

/** The MC offers the editor `label`; asked to start one, it does. */
export const hasEditor = (ctx: World, label: string) => {
  const editor = EDITORS.find((candidate) => candidate.label === label)!;
  beforeBoot(ctx, () => {
    ctx.fake!.override("getServerConfig", (async () => ({
      settings: DEFAULT_SERVER_SETTINGS,
      availableEditors: [editor.id],
    })) as never);
    ctx.fake!.settings.on("shell.openInEditor", () => null);
  });
};

step(
  "the thread runs on this computer, which has the editor {string}",
  (ctx: World, label: string) => hasEditor(ctx, label),
);

// Where the MC serving the thread is, as the client tells (thisMachine.ts):
// by the machine ids where both are known, else by being its own MC on loopback.
const HERE = "5e1f00000000000000000000000000000000000000000000000000000000c0de";
const ELSEWHERE = "a1".repeat(32);
const ELSEWHERES = {
  "an MC on another machine the client is paired with": {
    theirs: ELSEWHERE,
    own: true,
    origin: "ws://192.168.1.20:3773",
  },
  "an MC reached through an SSH port forward": {
    theirs: ELSEWHERE,
    own: true,
    origin: "ws://127.0.0.1:3773",
  },
} as const;

step(
  /^the thread's files are on (an MC on another machine the client is paired with|an MC reached through an SSH port forward)$/,
  (ctx: World, where: keyof typeof ELSEWHERES) => {
    hasEditor(ctx, "VS Code");
    beforeBoot(ctx, () => {
      ctx.fake!.override("localPathFor", async (path) =>
        hostedHere({ ours: HERE, ...ELSEWHERES[where] }) ? { path } : { problem: FILES_ELSEWHERE },
      );
    });
  },
);

// The client's own MC offers `own`, the member on this machine `member`: the fake
// settings MC answers each by the environment a call names (none: the client's own).
const MEMBER = "env-member";
const labelled = (label: string) => EDITORS.find((candidate) => candidate.label === label)!;

step(
  "the client is connected to an MC on another machine, which has the editor {string}",
  (ctx: World, label: string) => hasEditor(ctx, label),
);

step(
  "the thread runs on a cluster member on this computer, which has the editor {string}",
  (ctx: World, label: string) => {
    beforeBoot(ctx, () => {
      ctx.fake!.settings.on("server.getConfig", (_payload, environmentId) =>
        environmentId === MEMBER ? { availableEditors: [labelled(label).id] } : null,
      );
      ctx.fake!.override("localPathFor", async (path) => ({ path, environmentId: MEMBER }));
    });
  },
);

step(
  "{string} opens {string} on this computer through that member",
  async (ctx: World, label: string, path: string) => {
    await settle(ctx);
    expect(ctx.fake!.settings.callsTo("shell.openInEditor")).toEqual([
      {
        method: "shell.openInEditor",
        payload: { cwd: `${WORKSPACE}/${path}`, editor: labelled(label).id },
        environmentId: MEMBER,
      },
    ]);
    expect(status(ctx)).toEqual({ kind: "success", text: `Opened ${path} in ${label}.` });
  },
);

step("the user opens {string} in {string}", async (ctx: World, path: string, editor: string) => {
  await openFile(ctx, path);
  await chooseCommand(ctx, `Open file in ${editor}`);
  await settle(ctx);
});

step("the user opens {string} in an editor", async (ctx: World, path: string) => {
  await openFile(ctx, path);
  await chooseCommand(ctx, "Open file in VS Code");
  await settle(ctx);
});

step("nothing is started on that machine", (ctx: World) => {
  expect(mcCalls(ctx, "shell.openInEditor")).toEqual([]);
});

step(
  "the user is told the files are on another machine and can't be opened here yet",
  async (ctx: World) => {
    const screen = await settle(ctx);
    expect(status(ctx)).toEqual({
      kind: "error",
      text: "The files are on another machine and can't be opened here yet.",
    });
    expect(screen).toContain(statusLabel(ctx));
  },
);

step(
  "{string} opens {string} on this computer",
  async (ctx: World, label: string, path: string) => {
    const screen = await settle(ctx);
    const editor = EDITORS.find((candidate) => candidate.label === label)!;
    expect(mcCalls(ctx, "shell.openInEditor")).toEqual([
      { cwd: `${WORKSPACE}/${path}`, editor: editor.id },
    ]);
    expect(status(ctx)).toEqual({ kind: "success", text: `Opened ${path} in ${label}.` });
    expect(screen).toContain(statusLabel(ctx));
    // The file stays open here.
    expect(viewer(ctx).path).toBe(path);
  },
);

// --- Editing ------------------------------------------------------------------------------

/** Open the file and the editor in the viewer (`i`): the edit is typed here and saved as it goes. */
export async function editInPlace(ctx: ViewerWorld, path: string) {
  await openFile(ctx, path);
  servesWrites(ctx);
  await pressKey(ctx, "i");
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("fileEdit");
  expect(viewer(ctx)).toMatchObject({ path, editing: true, save: "saved" });
  expect(findObject(ctx, "fileEditor").get("focus")).toBe(true);
  ctx.original = editorText(ctx);
  expect(ctx.original).toContain("export const line1: number = 1;");
}

async function typeAndPause(ctx: ViewerWorld) {
  await typeText(ctx, CHANGE);
  await settle(ctx);
  // Nothing is written while the typing goes on.
  expect(viewer(ctx).save).toBe("pending");
  expect(writes(ctx)).toEqual([]);
  await advance(ctx, 500);
  await settle(ctx);
}

// "the user is editing {string}" is slice-files.steps.ts': in place here, in $EDITOR for tui/files.feature.
step("the user types a change and pauses", typeAndPause);

step("the change is written to {string}", async (ctx: ViewerWorld, path: string) => {
  const screen = await settle(ctx);
  const written = writes(ctx);
  expect(written).toHaveLength(1);
  expect(written[0]).toMatchObject({ cwd: WORKSPACE, relativePath: path });
  const contents = String(written[0]!.contents);
  expect(contents).toBe(editorText(ctx));
  expect(contents).toContain(CHANGE);
  expect(contents.replace(CHANGE, "")).toBe(ctx.original!);
  expect(viewer(ctx).save).toBe("saved");
  expect(status(ctx)).toEqual({ kind: "success", text: `Saved ${path}.` });
  expect(screen).toContain("saved · Esc done");
});

step("writing {string} fails", (ctx: ViewerWorld, path: string) => {
  (ctx.writeErrors ??= {})[path] = "permission denied";
});

step("the user edits {string}", async (ctx: ViewerWorld, path: string) => {
  await editInPlace(ctx, path);
  await typeAndPause(ctx);
});

step("the user is told the file could not be saved", async (ctx: ViewerWorld) => {
  const screen = await settle(ctx);
  expect(writes(ctx)).toHaveLength(1);
  expect(status(ctx)).toEqual({
    kind: "error",
    text: `Could not save ${viewer(ctx).path}: permission denied`,
  });
  expect(screen).toContain(statusLabel(ctx));
  expect(screen).toContain("not saved · Esc done");
});

step("the edit is still in the editor", async (ctx: ViewerWorld) => {
  expect(viewer(ctx)).toMatchObject({ editing: true, save: "error" });
  expect(editorText(ctx)).toContain(CHANGE);
  expect(await settle(ctx)).toContain(CHANGE);
  // Leaving tries again and, refused again, keeps the editor and what was typed.
  await pressKey(ctx, "Esc");
  await settle(ctx);
  expect(ctx.host!.state.get("mode")).toBe("fileEdit");
  expect(editorText(ctx)).toContain(CHANGE);
});

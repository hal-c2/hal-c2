import { describe, expect, it } from "bun:test";

import type { TuiFileText } from "../connection.ts";
import {
  createFilesController,
  TRUNCATED_READ_ONLY,
  type FilesControllerOptions,
  type TuiFilesState,
} from "./filesState.ts";

const START = "line\n".repeat(4);

/** The browser on `/w`, reading every file as `file` and recording the status row and clipboard. */
function viewerOf(file: TuiFileText) {
  const said: Array<{ text: string; kind: string | undefined }> = [];
  const copied: string[] = [];
  const written: string[] = [];
  let state: TuiFilesState | null = null;
  const options: FilesControllerOptions = {
    client: {
      listEntries: async () => [],
      readFile: async () => file,
      writeFile: async (_cwd, path) => {
        written.push(path);
      },
    },
    cwd: () => "/w",
    height: () => 20,
    width: () => 80,
    setOpen: () => {},
    publish: (next) => {
      state = next;
    },
    status: (text, kind) => said.push({ text, kind }),
    copy: (text) => {
      copied.push(text);
      return true;
    },
  };
  const files = createFilesController(options);
  return { files, said, copied, written, state: () => state };
}

describe("copying the open file", () => {
  it("says only the first 1 MB was copied when the MC read only that much", async () => {
    const { files, said, copied } = viewerOf({ contents: START, truncated: true });
    files.dispatch("files.view", { path: "logs/big.log" });
    await files.settled();
    files.dispatch("files.viewer.copy", undefined);
    expect(copied).toEqual([START]);
    expect(said.at(-1)).toEqual({
      text: "File contents copied: only the first 1 MB of logs/big.log.",
      kind: "warning",
    });
  });

  it("says the file was copied when it was read whole", async () => {
    const { files, said, copied } = viewerOf({ contents: START, truncated: false });
    files.dispatch("files.view", { path: "src/app.ts" });
    await files.settled();
    files.dispatch("files.viewer.copy", undefined);
    expect(copied).toEqual([START]);
    expect(said.at(-1)).toEqual({ text: "File contents copied.", kind: "success" });
  });
});

describe("editing the open file", () => {
  it("is refused when only its start was read, so a save cannot cut it short", async () => {
    const { files, said, written, state } = viewerOf({ contents: START, truncated: true });
    files.dispatch("files.view", { path: "logs/big.log" });
    await files.settled();
    expect(files.commands().map((command) => command.title)).not.toContain("Edit file here");
    files.dispatch("files.editor.open", undefined);
    files.dispatch("files.editor.set", { text: "cut" });
    files.dispatch("files.editor.done", undefined);
    await files.settled();
    expect(files.mode()).toBe("files");
    expect(state()?.viewer?.editing).toBe(false);
    expect(said.at(-1)).toEqual({ text: TRUNCATED_READ_ONLY, kind: "warning" });
    expect(written).toEqual([]);
  });
});

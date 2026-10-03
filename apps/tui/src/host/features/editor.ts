import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import { resolveEditorCommand, type EditorCommand } from "../../promptEditor.ts";
import { errorText, payloadField, type Feature, type FeatureKit } from "./kit.ts";

export interface EditorOptions {
  readonly env: { readonly VISUAL?: string | undefined; readonly EDITOR?: string | undefined };
  /** Run the editor on a file and resolve when it exits (the entry suspends the renderer). */
  readonly runEditor: (command: EditorCommand, file: string) => Promise<void>;
}

// Editors that take `file:line` (with `-g` for the VS Code family) instead of `+line file`.
const GOTO_FLAG = new Set(["code", "code-insiders", "codium", "cursor", "windsurf"]);
const FILE_COLON_LINE = new Set(["zed", "hx", "helix", "subl"]);

/** The command and file argument that open `file` at `line` in the user's editor. */
export function editorInvocation(
  command: EditorCommand,
  file: string,
  line: number | null,
): { readonly command: EditorCommand; readonly file: string } {
  if (line === null || line < 1) return { command, file };
  const name = NodePath.basename(command.cmd);
  if (GOTO_FLAG.has(name)) {
    return {
      command: { cmd: command.cmd, args: [...command.args, "-g"] },
      file: `${file}:${line}`,
    };
  }
  if (FILE_COLON_LINE.has(name)) return { command, file: `${file}:${line}` };
  return { command: { cmd: command.cmd, args: [...command.args, `+${line}`] }, file };
}

/**
 * A workspace file in the user's `$VISUAL` / `$EDITOR`: the MC's copy is
 * fetched into a temporary file, the editor runs on it, and a changed file is
 * written back. If the file changed in the workspace meanwhile, nothing is
 * overwritten: the user chooses which version stays.
 */
export function createEditorFeature(kit: FeatureKit, options: EditorOptions): Feature {
  const { client } = kit;

  const resolveConflict = (cwd: string, path: string, edited: string) => {
    kit.status(`${path} changed on disk while you edited it; nothing was overwritten.`, "error");
    kit.menu({
      title: `conflict · ${path}`,
      options: [
        {
          label: "Keep the file on disk",
          description: "Drop this edit.",
          value: "keep",
        },
        {
          label: "Overwrite with my edit",
          description: "Replace the newer file with what you just saved.",
          value: "overwrite",
        },
        {
          label: "Copy my edit",
          description: "Put your version on the clipboard and keep the file on disk.",
          value: "copy",
        },
      ],
      onChoose: (choice) => {
        if (choice === "overwrite") {
          void kit.track(
            client.writeFile(cwd, path, edited).then(
              () => kit.status(`Saved ${path} over the newer file.`, "success"),
              (error: unknown) => kit.status(`Save failed: ${errorText(error)}`, "error"),
            ),
          );
        } else if (choice === "copy") {
          const copied = kit.copy(edited);
          kit.status(
            copied
              ? `Your edit of ${path} is on the clipboard.`
              : "This terminal has no clipboard access.",
            copied ? "success" : "error",
          );
        } else kit.status(`Kept ${path} as it is on disk.`, "info");
      },
    });
  };

  const edit = (path: string, line: number | null) => {
    const workspace = kit.workspace();
    if (!workspace) {
      kit.status("Open a thread to edit its files.", "error");
      return;
    }
    const { cwd } = workspace;
    void kit.track(
      (async () => {
        const original = await client.readFile(cwd, path);
        if (original === null) {
          kit.status(`Could not read ${path}.`, "error");
          return;
        }
        const dir = await NodeFSP.mkdtemp(NodePath.join(NodeOS.tmpdir(), "hal-c2-edit-"));
        try {
          const file = NodePath.join(dir, NodePath.basename(path));
          await NodeFSP.writeFile(file, original, "utf8");
          kit.status(`Editing ${path} in $EDITOR…`, "busy");
          const invocation = editorInvocation(resolveEditorCommand(options.env), file, line);
          await options.runEditor(invocation.command, invocation.file);
          const edited = await NodeFSP.readFile(file, "utf8");
          if (edited === original) {
            kit.status(`No changes to ${path}.`, "info");
            return;
          }
          const onDisk = await client.readFile(cwd, path);
          if (onDisk !== original) {
            resolveConflict(cwd, path, edited);
            return;
          }
          await client.writeFile(cwd, path, edited);
          kit.status(`Saved ${path}.`, "success");
        } finally {
          await NodeFSP.rm(dir, { recursive: true, force: true });
        }
      })().catch((error: unknown) =>
        kit.status(`Could not edit ${path}: ${errorText(error)}`, "error"),
      ),
    );
  };

  /** The file the browser shows or has highlighted, and the line at the top of the viewer. */
  const browsed = (): { path: string; line: number | null } | null => {
    const files = kit.state.get("files") as
      | {
          open: boolean;
          viewer: { path: string; top: number } | null;
          rows: ReadonlyArray<{ kind: string; path: string; selected: boolean }>;
        }
      | undefined;
    if (!files?.open) return null;
    if (files.viewer) return { path: files.viewer.path, line: files.viewer.top + 1 };
    const row = files.rows.find((candidate) => candidate.selected && candidate.kind === "file");
    return row ? { path: row.path, line: null } : null;
  };

  return {
    commands: () =>
      browsed()
        ? [
            {
              id: "files.edit",
              title: "Edit file in $EDITOR",
              hint: "e",
              keywords: "open editor vim",
              action: "files.edit",
            },
          ]
        : [],
    dispatch: (action, payload) => {
      if (action === "files.edit") {
        const target = browsed();
        if (!target) return false;
        edit(target.path, target.line);
        return true;
      }
      if (action !== "file.edit") return false;
      const path = payloadField(payload, "path");
      const line = payloadField(payload, "line");
      if (typeof path === "string") edit(path, typeof line === "number" ? line : null);
      return true;
    },
  };
}

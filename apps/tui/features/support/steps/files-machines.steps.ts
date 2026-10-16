// Another machine's files opened from the folder the MC here keeps for it
// (files/files-on-another-machine.feature). The fake client stands in for the
// cluster client: asked where a member's checkout is here, it answers as the MC
// on this machine does (`files.localPath`, clusterClient.ts); the editor starts
// through that MC, never the member's.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { settle, type World } from "../world.ts";
import { type FilesWorld, openOnWorkspace } from "./files.steps.ts";
import { beforeBoot, hasEditor, mcCalls, status, statusLabel } from "./files-viewer.steps.ts";

/** Where the MC here mounts its members' folders. */
const FOLDERS = "/home/user/.local/state/hal-c2/elixir/machines";

interface MachinesWorld extends FilesWorld {
  /** The members of this MC's cluster, by label, and each one's project roots by title. */
  machines?: Record<string, Record<string, string>>;
  /** This machine has no FUSE: the MC says what to install instead of a path. */
  noFolders?: boolean;
}

const rootOf = (ctx: MachinesWorld, machine: string, project: string) => {
  const root = ctx.machines?.[machine]?.[project];
  if (root === undefined) throw new Error(`"${machine}" has no project "${project}"`);
  return root;
};

step("the client is connected to the MC on its own machine", () => {});

step("that MC is in a cluster with {string}", (ctx: MachinesWorld, machine: string) => {
  ctx.machines = { ...ctx.machines, [machine]: {} };
});

step(
  "{string} has the project {string} at {string}",
  (ctx: MachinesWorld, machine: string, project: string, root: string) => {
    ctx.machines = { ...ctx.machines, [machine]: { ...ctx.machines?.[machine], [project]: root } };
  },
);

step("this machine has no way to show another machine's folder", (ctx: MachinesWorld) => {
  ctx.noFolders = true;
});

step(
  "a thread of {string} runs on {string}",
  async (ctx: MachinesWorld, project: string, machine: string) => {
    const root = rootOf(ctx, machine, project);
    ctx.files = { "src/cart.ts": "export const cart = [];\n" };
    hasEditor(ctx, "VS Code");
    beforeBoot(ctx, () => {
      ctx.fake!.override("localPathFor", async (path) =>
        ctx.noFolders
          ? { problem: `The file is on "${machine}". To open it here, install FUSE 3 (fuse3).` }
          : { path: `${FOLDERS}/${machine}${path}` },
      );
    });
    await openOnWorkspace(ctx, root, project);
  },
);

step(
  "{string} on this machine opens {string} from the folder kept for {string}",
  async (ctx: MachinesWorld, label: string, path: string, machine: string) => {
    await settle(ctx);
    const root = rootOf(ctx, machine, "shop");
    expect(mcCalls(ctx, "shell.openInEditor")).toEqual([
      { cwd: `${FOLDERS}/${machine}${root}/${path}`, editor: "vscode" },
    ]);
    expect(status(ctx)).toEqual({ kind: "success", text: `Opened ${path} in ${label}.` });
  },
);

// Every editor went to the MC this client is paired with, which runs here: a
// call for another machine would name its environment.
step("nothing is started on {string}", (ctx: World, _machine: string) => {
  const addressed = ctx
    .fake!.settings.callsTo("shell.openInEditor")
    .map((call) => call.environmentId);
  expect(addressed.filter((environment) => environment !== undefined)).toEqual([]);
});

step(
  "the user is told the file is on {string} and what to install to open it here",
  async (ctx: World, machine: string) => {
    const screen = await settle(ctx);
    expect(status(ctx)).toEqual({
      kind: "error",
      text: `The file is on "${machine}". To open it here, install FUSE 3 (fuse3).`,
    });
    expect(screen).toContain(statusLabel(ctx));
    expect(mcCalls(ctx, "shell.openInEditor")).toEqual([]);
  },
);

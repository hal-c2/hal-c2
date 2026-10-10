// Steps for mc/platform/storage-layout.feature: where the terminal client looks
// for the user's shell. The run itself is `the user runs "hal-c2 tui"` (git.steps.ts),
// which starts the real client entry once a storage Given has set things up.
import { expect } from "bun:test";
import * as NodePath from "node:path";

import { step } from "../../steps.ts";
import { sandboxPath, storageSetup, type StorageWorld } from "../storageWorld.ts";

step("a Linux user with no XDG variables and no HAL-C2 home configured", (ctx: StorageWorld) => {
  storageSetup(ctx);
});

step("no HAL-C2 home is configured", (ctx: StorageWorld) => {
  delete storageSetup(ctx).env.HAL_C2_HOME;
});

for (const variable of ["XDG_CONFIG_HOME", "HAL_C2_HOME", "HAL_C2_TUI_SHELL_DIR"] as const) {
  step(`${variable} is {string}`, (ctx: StorageWorld, value: string) => {
    storageSetup(ctx).env[variable] = value;
  });
}

step(
  "the terminal client loads the user's shell from {string}",
  (ctx: StorageWorld, dir: string) => {
    expect(ctx.storageRun?.code).toBe(1);
    expect(ctx.storageRun?.stderr).toContain(NodePath.join(sandboxPath(ctx, dir), "keymap.json"));
    expect(ctx.storageRun?.stderr).toContain("is not valid JSON");
  },
);

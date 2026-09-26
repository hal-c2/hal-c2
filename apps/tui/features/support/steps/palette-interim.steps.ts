// INTERIM (T4): the command palette belongs to T3. Until it lands these steps
// run T4's palette entries (src/host/detailCommands.ts) through the palette's
// pure filter. Merger: delete this file once T3's palette steps exist, and
// have the palette merge `detailCommands` into its list.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { filterCommands } from "../../../src/commands.ts";
import { detailCommands } from "../../../src/host/detailCommands.ts";
import { ready, settle } from "../gitWorld.ts";
import { typeText, type World } from "../world.ts";

interface PaletteWorld extends World {
  paletteQuery?: string;
}

function commands(ctx: World) {
  const panel = ctx.host!.state.get("rightPanel") as { isOpen: boolean } | undefined;
  return detailCommands({
    panelOpen: panel?.isOpen ?? false,
    hasCheckpoints: true,
    dispatch: ctx.host!.dispatch,
  });
}

step("the command palette is open", async (ctx: PaletteWorld) => {
  await ready(ctx);
  ctx.paletteQuery = "";
});

step("the user types {string}", async (ctx: PaletteWorld, text: string) => {
  if (ctx.paletteQuery === undefined) {
    await typeText(ctx, text);
    return;
  }
  ctx.paletteQuery += text;
});

step("{string} is offered", (ctx: PaletteWorld, title: string) => {
  const offered = filterCommands(commands(ctx), ctx.paletteQuery ?? "").map((c) => c.title);
  expect(offered).toContain(title);
});

step("the user chooses {string} from the command palette", async (ctx: World, title: string) => {
  await ready(ctx);
  const command = filterCommands(commands(ctx), title).find((entry) => entry.title === title);
  expect(command, `no "${title}" in the palette`).toBeDefined();
  command!.run();
  await settle(ctx);
});

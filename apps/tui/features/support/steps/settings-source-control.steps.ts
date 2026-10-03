// Steps for settings/source-control.feature (@tui): the source control settings
// page lists the server's version-control and hosting tools with their state.
import { expect } from "bun:test";
import type { SourceControlDiscoveryResult } from "@hal-c2/contracts";
import * as Option from "effect/Option";

import { step } from "../../steps.ts";
import { toolRows } from "../../../src/host/sections/sourceControl.ts";
import { runPaletteCommand } from "./controls.steps.ts";
import { connected, pageText, paneWords, sectionState } from "../settingsWorld.ts";
import { useClient, type World } from "../world.ts";

const shared = { installHint: "Install it on the server.", detail: Option.none() };

/** Git, a signed-in GitHub, a signed-out GitLab and no Bitbucket CLI. */
const DISCOVERY = {
  versionControlSystems: [
    {
      kind: "git",
      implemented: true,
      label: "Git",
      status: "available",
      version: Option.some("2.45.0"),
      ...shared,
    },
  ],
  sourceControlProviders: [
    {
      kind: "github",
      label: "GitHub",
      status: "available",
      version: Option.some("2.60.0"),
      ...shared,
      auth: {
        status: "authenticated",
        account: Option.some("octocat"),
        host: Option.some("github.com"),
        detail: Option.none(),
      },
    },
    {
      kind: "gitlab",
      label: "GitLab",
      status: "available",
      version: Option.some("1.40.0"),
      ...shared,
      auth: {
        status: "unauthenticated",
        account: Option.none(),
        host: Option.none(),
        detail: Option.some("Run glab auth login"),
      },
    },
    {
      kind: "bitbucket",
      label: "Bitbucket",
      status: "missing",
      version: Option.none(),
      ...shared,
      installHint: "Install the Bitbucket CLI",
      auth: {
        status: "unknown",
        account: Option.none(),
        host: Option.none(),
        detail: Option.none(),
      },
    },
  ],
} as unknown as SourceControlDiscoveryResult;

step("the user is connected to an environment and opens Settings, Source Control", (ctx: World) => {
  useClient(ctx, { discoverSourceControl: async () => DISCOVERY });
});

step("the user opens source control settings in the terminal client", async (ctx: World) => {
  await connected(ctx);
  await runPaletteCommand(ctx, "Source control settings");
  expect(sectionState(ctx).id).toBe("sourceControl");
  expect(ctx.host!.state.get("mode")).toBe("section");
});

step("each tool is shown as authenticated, unavailable or needing setup", async (ctx: World) => {
  const screen = await paneWords(ctx);
  expect(toolRows(DISCOVERY).map((row) => `${row.label}: ${row.state}`)).toEqual([
    "Git: available",
    "GitHub: authenticated",
    "GitLab: needs setup",
    "Bitbucket: unavailable",
  ]);
  expect(screen).toContain("GitHub authenticated · as octocat");
  expect(screen).toContain("GitLab needs setup · Run glab auth login");
  expect(screen).toContain("Bitbucket unavailable · Install the Bitbucket CLI");
  expect(screen).toContain("Git available · 2.45.0");
  expect(pageText(ctx)).toContain("Rescan Git and hosting tools");
});

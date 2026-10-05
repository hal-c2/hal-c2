// Background steps the settings features share (features/settings/*): the MC
// the terminal is connected to and the projects it has.
import { step } from "../../steps.ts";
import { fixture, type SettingsWorld } from "../settingsWorld.ts";

step("an MC with a project {string}", (ctx: SettingsWorld, project: string) => {
  fixture(ctx).projects.push(project);
});

import { describe, expect, it } from "bun:test";

import { fakeClient } from "../../../features/support/fakeClient.ts";
import { createHost } from "../host.ts";
import type { TuiSettingsSectionState } from "../settingsSections.ts";

// features/settings/project-environment.feature: the project's page shows where
// its sessions load its environment from, says what loading runs, and changes it
// as the project's override in the MC's settings.
function boot() {
  const fake = fakeClient();
  const document = { settings: { theme: "dark" } as Record<string, unknown>, version: 1 };
  fake.settings.on("hal-c2.readSettings", () => ({ ...document }));
  fake.settings.on("hal-c2.writeSettings", (payload) => {
    if (payload.version !== document.version) throw new Error("settings changed");
    document.settings = payload.settings;
    document.version += 1;
    return { version: document.version };
  });
  const host = createHost({ client: fake.client, size: { columns: 160, rows: 50 }, log: () => {} });
  const text = () =>
    (host.state.get("settingsSection") as TuiSettingsSectionState).lines.join("\n");
  return { fake, host, document, text };
}

const overrides = (document: { settings: Record<string, unknown> }) =>
  (document.settings.projectSettingsOverrides as Record<string, Record<string, unknown>>)?.p1;

describe("project environment", () => {
  it("is off until chosen, cycles through its sources and back to off", async () => {
    const { fake, host, document, text } = boot();
    fake.connect();
    host.dispatch("section.open", { id: "projects", projectId: "p1" });
    await host.settled();
    expect(text()).toMatch(/Project environment\s+Off/);
    expect(text()).toContain("only for a checkout you trust");
    expect(text()).not.toContain("Dotenv file");

    host.dispatch("section.activate", { id: "environment" });
    await host.settled();
    expect(overrides(document)).toEqual({ projectEnvironment: "auto" });
    expect(document.settings.theme).toBe("dark");
    expect(text()).toMatch(/Project environment\s+mise and direnv/);

    host.dispatch("section.activate", { id: "environment" });
    await host.settled();
    expect(text()).toMatch(/Project environment\s+A dotenv file/);
    expect(text()).toMatch(/Dotenv file\s+\.env/);

    host.dispatch("section.activate", { id: "environment" });
    await host.settled();
    expect(overrides(document)).toEqual({ projectEnvironment: "off" });
    expect(text()).toMatch(/Project environment\s+Off/);
    host.destroy();
  });

  it("takes the dotenv file through the field", async () => {
    const { fake, host, document, text } = boot();
    document.settings = { projectSettingsOverrides: { p1: { projectEnvironment: "dotenv" } } };
    fake.connect();
    host.dispatch("section.open", { id: "projects", projectId: "p1" });
    await host.settled();
    host.dispatch("section.activate", { id: "environment-file" });
    expect(host.state.get("mode")).toBe("sectionInput");
    host.dispatch("section.input.submit", { text: ".env.a" });
    await host.settled();
    expect(overrides(document)).toEqual({
      projectEnvironment: "dotenv",
      projectEnvironmentFile: ".env.a",
    });
    expect(text()).toMatch(/Dotenv file\s+\.env\.a/);
    host.destroy();
  });
});

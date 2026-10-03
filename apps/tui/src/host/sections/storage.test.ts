import { describe, expect, it } from "bun:test";

import { fakeClient } from "../../../features/support/fakeClient.ts";
import { createHost } from "../host.ts";
import type { TuiSettingsSectionState } from "../settingsSections.ts";

function boot() {
  const fake = fakeClient({
    getServerConfig: (async () => ({
      settings: {},
      environment: { environmentId: "here", label: "Here", capabilities: { storageCleanup: true } },
    })) as never,
  });
  const document = { settings: { theme: "dark" } as Record<string, unknown>, version: 4 };
  let staleOnce = true;
  fake.settings.on("hal-c2.readSettings", () => ({ ...document }));
  fake.settings.on("hal-c2.writeSettings", (payload) => {
    // Another client wrote first: the MC asks for the change again.
    if (staleOnce) {
      staleOnce = false;
      document.version += 1;
      throw new Error("settings changed");
    }
    if (payload.version !== document.version) throw new Error("settings changed");
    document.settings = payload.settings;
    document.version += 1;
    return { version: document.version };
  });
  const host = createHost({ client: fake.client, size: { columns: 120, rows: 40 }, log: () => {} });
  const page = () => host.state.get("settingsSection") as TuiSettingsSectionState;
  return { fake, host, document, page };
}

describe("storage settings", () => {
  it("turns a rule on, keeping the other settings and retrying a stale write", async () => {
    const { fake, host, document, page } = boot();
    fake.connect();
    host.dispatch("section.open", { id: "storage" });
    await host.settled();
    expect(page().lines.join("\n")).toMatch(/Delete merged worktrees\s+off/);

    host.dispatch("section.activate", { id: "rule-worktreeOnMerge" });
    await host.settled();
    expect(document.settings).toEqual({ theme: "dark", storageCleanup: { worktreeOnMerge: true } });
    expect(fake.settings.callsTo("hal-c2.writeSettings")).toHaveLength(2);
    expect(page().lines.join("\n")).toMatch(/Delete merged worktrees\s+on/);
    host.destroy();
  });

  it("takes a number of days through the field, and blank turns the rule off", async () => {
    const { fake, host, document, page } = boot();
    fake.connect();
    host.dispatch("section.open", { id: "storage" });
    await host.settled();
    host.dispatch("section.activate", { id: "rule-logsAfterDays" });
    expect(host.state.get("mode")).toBe("sectionInput");
    host.dispatch("section.input.submit", { text: "30" });
    await host.settled();
    expect(document.settings.storageCleanup).toEqual({ logsAfterDays: 30 });
    expect(page().lines.join("\n")).toMatch(/Delete old rotated logs\s+after 30 days/);

    host.dispatch("section.activate", { id: "rule-logsAfterDays" });
    host.dispatch("section.input.submit", { text: "" });
    await host.settled();
    expect(document.settings.storageCleanup).toEqual({ logsAfterDays: null });
    host.destroy();
  });
});

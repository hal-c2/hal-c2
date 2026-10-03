import { describe, expect, it } from "bun:test";

import { fakeClient } from "../../../features/support/fakeClient.ts";
import { createHost } from "../host.ts";
import type { TuiSettingsSectionState } from "../settingsSections.ts";
import { hubIdFromUrl, hubLabel } from "./usageHubs.ts";

describe("usage hubs", () => {
  it("keys a hub by its host and port, and labels an unlabelled one by its host", () => {
    expect(hubIdFromUrl("https://Hub.Example.ts.net:8318/v0")).toBe(
      "cliproxy-hub.example.ts.net-8318",
    );
    expect(hubIdFromUrl("not a url")).toBe("cliproxy-not-a-url");
    expect(hubLabel({ url: "https://hub.example:8317" })).toBe("hub.example:8317");
    expect(hubLabel({ url: "https://hub.example", label: " Team hub " })).toBe("Team hub");
  });

  it("removes a hub only after the user confirms, leaving the other settings", async () => {
    const fake = fakeClient();
    const document = {
      settings: {
        theme: "dark",
        usageLimitSources: {
          "team-hub": { kind: "cliproxy", label: "Team hub", url: "https://hub.example" },
        },
      } as Record<string, unknown>,
      version: 1,
    };
    fake.settings.on("hal-c2.readSettings", () => ({ ...document }));
    fake.settings.on("hal-c2.writeSettings", (payload) => {
      document.settings = payload.settings;
      document.version += 1;
      return { version: document.version };
    });
    const host = createHost({
      client: fake.client,
      size: { columns: 120, rows: 40 },
      log: () => {},
    });
    const page = () => host.state.get("settingsSection") as TuiSettingsSectionState;
    fake.connect();
    host.dispatch("section.open", { id: "usageHubs" });
    await host.settled();
    expect(page().lines.join("\n")).toContain("Team hub");

    host.dispatch("section.activate", { id: "hub-team-hub" });
    expect(host.state.get("mode")).toBe("sectionConfirm");
    host.dispatch("section.confirm.no");
    await host.settled();
    expect(fake.settings.callsTo("hal-c2.writeSettings")).toEqual([]);

    host.dispatch("section.activate", { id: "hub-team-hub" });
    host.dispatch("section.confirm.yes");
    await host.settled();
    expect(document.settings).toEqual({ theme: "dark", usageLimitSources: {} });
    // One settings write is all that happened: nothing is sent to the hub.
    expect(fake.settings.callsTo("hal-c2.writeSettings")).toHaveLength(1);
    expect(page().lines.join("\n")).not.toContain("Team hub");
    host.destroy();
  });
});

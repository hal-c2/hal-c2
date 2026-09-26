import { describe, expect, it } from "bun:test";

import { fakeClient, shell } from "../../features/support/fakeClient.ts";
import type { OrchestrationShellSnapshot } from "../connection.ts";
import { createHost } from "./host.ts";

const NOW = "2026-07-14T00:00:00.000Z";

function boot(columns = 140) {
  const fake = fakeClient();
  const logged: string[] = [];
  const host = createHost({
    client: fake.client,
    size: { columns, rows: 40 },
    log: (message) => logged.push(message),
    now: () => NOW,
  });
  return { ...fake, host, logged, get: (key: string) => host.state.get(key) as any };
}

describe("createHost", () => {
  it("says Connecting… until the first shell snapshot, then counts", () => {
    const { host, connect, get } = boot();
    expect(get("status")).toEqual({ kind: "busy", text: "Connecting…" });
    expect(get("page")).toEqual({ kind: "none" });
    connect();
    expect(get("status").text).toBe("1 project(s) · 1 thread(s)");
    expect(get("sidebar").activeThreadKey).toBe("local:t1");
    expect(get("page")).toMatchObject({ kind: "thread", title: "Thread one" });
    host.destroy();
  });

  it("opens the filter over the conversation only when the list cannot dock", () => {
    const wide = boot(140);
    wide.host.dispatch("sidebar.filter.focus");
    expect(wide.get("mode")).toBe("filter");
    expect(wide.get("layout")).toMatchObject({ sidebarVisible: true, sidebarAsMain: false });

    const narrow = boot(70);
    expect(narrow.get("layout")).toMatchObject({ sidebarVisible: false, mainWidth: 70 });
    narrow.host.dispatch("sidebar.filter.focus");
    expect(narrow.get("layout").sidebarAsMain).toBe(true);
    narrow.host.dispatch("sidebar.filter.cancel");
    expect(narrow.get("mode")).toBe("compose");
    expect(narrow.get("layout").sidebarAsMain).toBe(false);
  });

  it("filters the thread list and clears it on cancel", () => {
    const { host, emitShell, get } = boot();
    emitShell(
      shell([
        { id: "t1", projectId: "p1", title: "Fix login", updatedAt: NOW, session: null },
        { id: "t2", projectId: "p1", title: "Write docs", updatedAt: NOW, session: null },
      ] as unknown as OrchestrationShellSnapshot["threads"]),
    );
    host.dispatch("sidebar.filter.set", { query: "docs" });
    expect(get("sidebar").active.map((t: { title: string }) => t.title)).toEqual(["Write docs"]);
    host.dispatch("sidebar.filter.cancel");
    expect(get("sidebar").active).toHaveLength(2);
    expect(get("sidebar").filter).toBe("");
  });

  it("collapses the docked list and follows resizes", () => {
    const { host, get } = boot(140);
    host.dispatch("sidebar.toggle");
    expect(get("layout")).toMatchObject({ sidebarCollapsed: true, sidebarVisible: false });
    host.dispatch("sidebar.toggle");
    host.resize({ columns: 60, rows: 20 });
    expect(get("size")).toEqual({ columns: 60, rows: 20 });
    expect(get("layout").sidebarVisible).toBe(false);
  });

  it("logs an unknown action once", () => {
    const { host, logged } = boot();
    host.dispatch("nope");
    host.dispatch("nope");
    expect(logged).toEqual(['t3 tui: unknown shell action "nope"']);
  });
});

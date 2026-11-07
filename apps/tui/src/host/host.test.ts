import { describe, expect, it } from "bun:test";

import { DEFAULT_SERVER_SETTINGS } from "@hal-c2/contracts";

import { fakeClient, projectTwo, shell } from "../../features/support/fakeClient.ts";
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

  it("lists settled plugin threads as the MC's setting says, whichever device changed it", async () => {
    const { host, connect, emitShell, settings, get } = boot();
    connect();
    const settled = { settledOverride: "settled", updatedAt: NOW, session: null, latestTurn: null };
    emitShell(
      shell([
        { id: "t1", projectId: "p1", title: "Fix login", ...settled },
        {
          id: "t2",
          projectId: "p1",
          title: "Review 1",
          ...settled,
          plugin: { id: "code-review", kind: "review", listed: true },
        },
      ] as unknown as OrchestrationShellSnapshot["threads"]),
    );
    await host.settled();
    expect(get("sidebar").settledTotal).toBe(1);

    // Another device turns it on; the MC pushes its settings to every client.
    settings.emitServerSettings({
      ...DEFAULT_SERVER_SETTINGS,
      sidebarShowSettledPluginThreads: true,
    });
    expect(get("sidebar").settledTotal).toBe(2);
    // A config read answers with the config the session connected with; it does not undo that.
    host.dispatch("providers.refresh");
    await host.settled();
    expect(get("sidebar").settledTotal).toBe(2);

    // Reconnected after it was turned off meanwhile: the new session's snapshot says so.
    settings.emitServerSettings({
      ...DEFAULT_SERVER_SETTINGS,
      sidebarShowSettledPluginThreads: false,
    });
    expect(get("sidebar").settledTotal).toBe(1);
    host.destroy();
  });

  it("logs an unknown action once", () => {
    const { host, logged } = boot();
    host.dispatch("nope");
    host.dispatch("nope");
    expect(logged).toEqual(['hal-c2 tui: unknown shell action "nope"']);
  });

  describe("a new thread's draft moved to another project", () => {
    const refs = (names: string[]) =>
      ({
        refs: names.map((name, i) => ({
          name,
          current: i === 0,
          isDefault: i === 0,
          worktreePath: null,
        })),
        isRepo: true,
        hasPrimaryRemote: true,
        nextCursor: null,
        totalCount: names.length,
      }) as never;

    it("ignores the old project's branches when they land after the move", async () => {
      let releaseOld!: () => void;
      const fake = fakeClient({
        shellSnapshot: shell(undefined, [
          { id: "p1", title: "Project one", workspaceRoot: "/workspace/project-one" },
          projectTwo,
        ] as never),
        listRefs: (async (cwd: string) => {
          if (cwd === "/workspace/project-one") {
            await new Promise<void>((resolve) => (releaseOld = resolve));
            return refs(["old-only"]);
          }
          return refs(["main", "feature"]);
        }) as never,
      });
      const host = createHost({
        client: fake.client,
        size: { columns: 140, rows: 40 },
        log: () => {},
        now: () => NOW,
      });
      fake.connect();
      host.dispatch("thread.new", { projectKey: "local:p1" });
      host.dispatch("composer.projectPicker.toggle");
      host.dispatch("select.choose", { index: 1 });
      await host.settled();
      releaseOld();
      await host.settled();
      const draft = host.state.get("newThread") as any;
      expect(draft.branch).toBe("main");
      expect(JSON.stringify(draft)).not.toContain("old-only");
      host.destroy();
    });

    it("puts the highlight back on the current project when the search is cleared", () => {
      const fake = fakeClient({
        shellSnapshot: shell(undefined, [
          { id: "p1", title: "Project one", workspaceRoot: "/workspace/project-one" },
          projectTwo,
        ] as never),
      });
      const host = createHost({
        client: fake.client,
        size: { columns: 140, rows: 40 },
        log: () => {},
        now: () => NOW,
      });
      fake.connect();
      host.dispatch("thread.new", { projectKey: "local:p2" });
      host.dispatch("composer.projectPicker.toggle");
      expect((host.state.get("select") as any).index).toBe(1);
      host.dispatch("select.query.set", { query: "one" });
      expect((host.state.get("select") as any).index).toBe(0);
      host.dispatch("select.query.set", { query: "" });
      expect((host.state.get("select") as any).index).toBe(1);
      host.destroy();
    });
  });
});

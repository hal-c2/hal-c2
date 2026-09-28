import { describe, expect, it } from "vite-plus/test";

import { sameShellRoute, shellRouteFromPath } from "./shellRoute";

const EMPTY = { threadKey: null, draftId: null, projectKey: null, section: null };

describe("shellRouteFromPath", () => {
  it("names the routes the shell navigates between", () => {
    expect(shellRouteFromPath("/")).toEqual({ kind: "home", ...EMPTY });
    expect(shellRouteFromPath("/env-a/t1")).toEqual({
      kind: "thread",
      ...EMPTY,
      threadKey: "env-a:t1",
    });
    expect(shellRouteFromPath("/draft/d1")).toEqual({ kind: "draft", ...EMPTY, draftId: "d1" });
    expect(shellRouteFromPath("/pull-requests")).toEqual({ kind: "pullRequests", ...EMPTY });
    expect(shellRouteFromPath("/usage")).toEqual({ kind: "usage", ...EMPTY });
  });

  it("keeps the settings section, or none while settings pick one", () => {
    expect(shellRouteFromPath("/settings/providers")).toEqual({
      kind: "settings",
      ...EMPTY,
      section: "/settings/providers",
    });
    expect(shellRouteFromPath("/settings")).toEqual({ kind: "settings", ...EMPTY });
  });

  it("decodes the thread's ids", () => {
    expect(shellRouteFromPath("/env%20a/t%3A1")?.threadKey).toBe("env a:t:1");
  });

  it("has no route for pairing, onboarding, project pages or embeds", () => {
    for (const path of ["/pair", "/connect", "/welcome", "/projects/p1", "/embed/env-a/t1"]) {
      expect(shellRouteFromPath(path)).toBeNull();
    }
  });
});

describe("sameShellRoute", () => {
  it("compares every field", () => {
    const thread = shellRouteFromPath("/env-a/t1")!;
    expect(sameShellRoute(thread, shellRouteFromPath("/env-a/t1")!)).toBe(true);
    expect(sameShellRoute(thread, shellRouteFromPath("/env-a/t2")!)).toBe(false);
  });
});

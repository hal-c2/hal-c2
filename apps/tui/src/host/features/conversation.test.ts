import { describe, expect, it } from "bun:test";

import { createConversationFeature, filePaths } from "./conversation.ts";
import type { FeatureKit, FeatureWorkspace } from "./kit.ts";

describe("filePaths", () => {
  it("takes link targets and bare paths, in order, each once", () => {
    expect(
      filePaths("See [the guide](./docs/guide.md#install), then README.md and docs/guide.md."),
    ).toEqual(["docs/guide.md", "README.md"]);
  });

  it("leaves out URLs and paths that climb out of the project", () => {
    expect(filePaths("Read https://example.com/a.md and ../other/notes.md")).toEqual([]);
  });
});

describe("opening a file the conversation names in a Space", () => {
  const offered = (workspace: FeatureWorkspace) => {
    const dispatched: Array<{ action: string; payload: unknown }> = [];
    const kit = {
      store: { getState: () => ({ detail: { messages: [{ text: "See [it](docs/guide.md)." }] } }) },
      workspace: () => workspace,
      status: () => {},
      dispatch: (action: string, payload: unknown) => dispatched.push({ action, payload }) > 0,
    } as unknown as FeatureKit;
    const feature = createConversationFeature(kit);
    const ids = (feature.commands?.() ?? []).map((command) => command.id);
    feature.dispatch("reference.space", undefined);
    return { ids, dispatched };
  };

  it("is offered for this machine's project", () => {
    const { ids, dispatched } = offered({
      threadId: "t1",
      projectId: "p1",
      home: true,
      worktree: false,
      cwd: "/w",
    });
    expect(ids).toContain("reference.space");
    expect(dispatched).toEqual([
      { action: "space.openProjectFile", payload: { projectId: "p1", paths: ["docs/guide.md"] } },
    ]);
  });

  it("is not offered for another machine's, and never sends its id", () => {
    const remote = {
      threadId: "t1",
      projectId: "env2:p9",
      home: false,
      worktree: false,
      cwd: "/w",
    };
    const { ids, dispatched } = offered(remote);
    expect(ids).not.toContain("reference.space");
    expect(dispatched).toEqual([]);
  });
});

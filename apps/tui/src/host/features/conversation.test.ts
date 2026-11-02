import { describe, expect, it } from "bun:test";

import { filePaths } from "./conversation.ts";

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

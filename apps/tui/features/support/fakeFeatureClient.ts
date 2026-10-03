// The fake's side of src/featureClient.ts: an in-memory answer for each
// request the feature areas make. Scenarios shape it through `ctx.fake.server`
// (or swap one method with `ctx.fake.override`).
import type { TuiFeatureClient } from "../../src/featureClient.ts";

/** What the fake MC holds for the feature areas. */
export interface FakeServer {
  /** Files written through `writeFile`, by `cwd:relativePath`. */
  readonly written: Map<string, string>;
}

export function fakeFeatureClient(): { client: TuiFeatureClient; server: FakeServer } {
  const server: FakeServer = { written: new Map() };
  const client: TuiFeatureClient = {
    writeFile: async (cwd, relativePath, contents) => {
      server.written.set(`${cwd}:${relativePath}`, contents);
    },
  };
  return { client, server };
}

import { describe, expect, it } from "vite-plus/test";

import { extractTerminalLinks } from "./terminalLinks.ts";

const paths = (line: string) =>
  extractTerminalLinks(line)
    .filter((match) => match.kind === "path")
    .map((match) => match.text);

describe("extractTerminalLinks paths", () => {
  it.each([
    "GET /api/users?id=1",
    "GET /api/trpc/post.list,user.me?batch=1 200",
    "proxying /api/users?page=2 to localhost:4000",
    "/src/App.tsx?t=1",
  ])("finds no path in the request route or query in %s", (line) => {
    expect(paths(line)).toEqual([]);
  });

  it.each([
    "Connected to redis://127.0.0.1:6379/0",
    "postgres://app@localhost:5432/shop",
    "uploaded to s3://bucket/key",
    "at main (file:///Users/me/app/src/index.mjs:3:7)",
  ])("finds no path in the non-web address in %s", (line) => {
    expect(paths(line)).toEqual([]);
  });

  it("still links a file path beside a non-web address", () => {
    expect(paths("src/config.ts:12 uses redis://127.0.0.1:6379/0")).toEqual(["src/config.ts:12"]);
  });

  it("still links absolute paths", () => {
    expect(paths("error in C:\\work\\app\\src\\index.ts:3:7")).toEqual([
      "C:\\work\\app\\src\\index.ts:3:7",
    ]);
    expect(paths("see /usr/local/lib/app.js:9")).toEqual(["/usr/local/lib/app.js:9"]);
  });
});

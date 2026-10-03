// Searching a project's contents from the terminal (files/search.feature): the
// fake MC greps the checkout's files as `projects.searchContents` does.
import { expect } from "bun:test";

import { step } from "../../steps.ts";
import { projectNamed, ui } from "../environment.ts";
import { projectsMc, writeProjectFile } from "../projectsWorld.ts";
import { fillField, sectionState } from "../settingsWorld.ts";
import { chooseCommand } from "../threadUi.ts";
import { settle, type World } from "../world.ts";

step(
  /^"([^"]+)" holds ((?:"[^"]+", )*"[^"]+") and "([^"]+)"$/,
  (ctx: World, project: string, list: string, last: string) => {
    const paths = [...list.matchAll(/"([^"]+)"/g)].map((match) => match[1]!);
    for (const path of [...paths, last]) writeProjectFile(ctx, project, path, `// ${path}\n`);
  },
);

step("{string} contains the line {string}", (ctx: World, path: string, line: string) => {
  writeProjectFile(ctx, "shop", path, `import { items } from "./items";\n\n${line}\n`);
});

step("the user searches the project contents for {string}", async (ctx: World, query: string) => {
  const mc = projectsMc(ctx);
  await ui(ctx);
  // Case-insensitive plain text over text files, a match per line, as the MC answers.
  ctx.fake!.settings.on("projects.searchContents", (input) => {
    const needle = String(input.query).toLowerCase();
    const matches = [...mc.files]
      .filter(([path]) => path.startsWith(`${input.cwd}/`) && !path.endsWith(".png"))
      .flatMap(([path, contents]) =>
        contents.split("\n").flatMap((lineContent, index) => {
          const start = lineContent.toLowerCase().indexOf(needle);
          return start < 0
            ? []
            : [
                {
                  path: path.slice(String(input.cwd).length + 1),
                  lineNumber: index + 1,
                  lineContent,
                  matchRanges: [{ start, end: start + needle.length }],
                },
              ];
        }),
      );
    return { matches: matches.slice(0, input.limit), truncated: matches.length > input.limit };
  });
  await chooseCommand(ctx, "Search project contents");
  await fillField(ctx, query);
});

step("{string} is listed with its matching line", async (ctx: World, path: string) => {
  const screen = await settle(ctx);
  expect(ctx.fake!.settings.callsTo("projects.searchContents").map((call) => call.payload)).toEqual(
    [
      expect.objectContaining({
        cwd: projectNamed(ctx, "shop").workspaceRoot,
        query: "total",
        caseSensitive: false,
      }),
    ],
  );
  const lines = sectionState(ctx).lines;
  const heading = lines.indexOf(path);
  expect(heading).toBeGreaterThan(0);
  // The line that holds the text, under its file, with its line number.
  expect(lines[heading + 1]).toMatch(/^\s+3\s+const Total = cartTotal\(items\)$/);
  expect(screen).toContain(path);
  expect(screen).toContain("const Total = cartTotal(items)");
  // Files that only match by name are not content matches.
  expect(lines).not.toContain("docs/shopping-cart.md");
});

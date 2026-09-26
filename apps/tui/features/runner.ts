// Gherkin runner for the terminal client: `bun run features` (bun test).
//
// Picks scenarios tagged @tui or @shared from the repo's features/, minus
// @dropped; @backlog is skipped unless TUI_INCLUDE_BACKLOG=1. Choose files with
// TUI_FEATURES="tui/layout.feature tui/launch.feature" (globs relative to
// features/, default "tui/**"). Steps live in support/steps/ and steps/
// (`*.steps.ts`); see steps.ts for how they are written.
import { describe, test } from "bun:test";
import { Glob } from "bun";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import { generateMessages } from "@cucumber/gherkin";
import {
  IdGenerator,
  SourceMediaType,
  type GherkinDocument,
  type Pickle,
} from "@cucumber/messages";

import { matchStep, type StepContext } from "./steps.ts";

const FEATURES_ROOT = NodePath.resolve(import.meta.dir, "../../../features");
const SCENARIO_TIMEOUT_MS = 20_000;
const includeBacklog = process.env.TUI_INCLUDE_BACKLOG === "1";

function selectedPatterns(): string[] {
  const fromEnv = (process.env.TUI_FEATURES ?? "").split(/[\s,]+/).filter(Boolean);
  if (fromEnv.length > 0) return fromEnv;
  const dashDash = process.argv.indexOf("--");
  const fromArgs = dashDash >= 0 ? process.argv.slice(dashDash + 1) : [];
  return fromArgs.length > 0 ? fromArgs : ["tui/**"];
}

function featureFiles(patterns: ReadonlyArray<string>): string[] {
  const files = new Set<string>();
  for (const raw of patterns) {
    const pattern = raw.replace(/^(\.\/)?features\//, "");
    const glob = pattern.endsWith(".feature")
      ? pattern
      : `${pattern.replace(/\/?\*\*$/, "").replace(/\/$/, "")}/**/*.feature`;
    for (const file of new Glob(glob).scanSync({ cwd: FEATURES_ROOT })) files.add(file);
  }
  return [...files].toSorted();
}

async function loadSteps(): Promise<void> {
  for (const dir of ["support/steps", "steps"]) {
    const cwd = NodePath.join(import.meta.dir, dir);
    if (!NodeFS.existsSync(cwd)) continue;
    const files = [...new Glob("**/*.steps.ts").scanSync({ cwd })].toSorted();
    for (const file of files) await import(NodePath.join(cwd, file));
  }
}

/** Step id → keyword and line, for Cucumber-style failure messages. */
function stepLocations(document: GherkinDocument | undefined) {
  const locations = new Map<string, { keyword: string; line: number }>();
  const visit = (children: ReadonlyArray<any>) => {
    for (const child of children) {
      const node = child.background ?? child.scenario;
      for (const s of node?.steps ?? []) {
        locations.set(s.id, { keyword: s.keyword.trim(), line: s.location.line });
      }
      if (child.rule) visit(child.rule.children);
    }
  };
  visit(document?.feature?.children ?? []);
  return locations;
}

function snippet(text: string): string {
  const pattern = text.replace(/"[^"]*"/g, "{string}").replace(/\b\d+\b/g, "{int}");
  return `step(${JSON.stringify(pattern)}, async (ctx) => {\n    // ...\n  });`;
}

const isSelected = (tags: ReadonlyArray<string>) =>
  (tags.includes("@tui") || tags.includes("@shared")) && !tags.includes("@dropped");

async function runPickle(
  uri: string,
  pickle: Pickle,
  locations: ReturnType<typeof stepLocations>,
): Promise<void> {
  let ctx: StepContext = { tags: pickle.tags.map((tag) => tag.name), cleanups: [] };
  try {
    for (const pickleStep of pickle.steps) {
      const where = locations.get(pickleStep.astNodeIds[0] ?? "");
      const label = `${where?.keyword ?? "*"} ${pickleStep.text}`;
      const match = matchStep(pickleStep.text);
      if (!match) {
        throw new Error(
          `Undefined step: ${label}\n  (features/${uri}:${where?.line ?? "?"})\n\n` +
            `Implement it in apps/tui/features/steps/**/*.steps.ts:\n  ${snippet(pickleStep.text)}`,
        );
      }
      const argument = pickleStep.argument;
      const extra =
        argument?.docString !== undefined
          ? [argument.docString.content]
          : argument?.dataTable !== undefined
            ? [argument.dataTable.rows.map((row) => row.cells.map((cell) => cell.value))]
            : [];
      try {
        const next = await match.fn(ctx, ...match.args, ...extra);
        if (next && typeof next === "object") ctx = next;
      } catch (error) {
        if (error instanceof Error) {
          error.message = `${label}\n  (features/${uri}:${where?.line ?? "?"})\n${error.message}`;
        }
        throw error;
      }
    }
  } finally {
    const cleanups = (ctx.cleanups ?? []) as Array<() => unknown>;
    for (const cleanup of cleanups.toReversed()) await cleanup();
  }
}

await loadSteps();

for (const uri of featureFiles(selectedPatterns())) {
  const source = NodeFS.readFileSync(NodePath.join(FEATURES_ROOT, uri), "utf8");
  const envelopes = generateMessages(source, uri, SourceMediaType.TEXT_X_CUCUMBER_GHERKIN_PLAIN, {
    includeGherkinDocument: true,
    includePickles: true,
    newId: IdGenerator.incrementing(),
  });
  const parseError = envelopes.find((envelope) => envelope.parseError)?.parseError;
  const document = envelopes.find((envelope) => envelope.gherkinDocument)?.gherkinDocument;
  const pickles = envelopes.flatMap((envelope) => (envelope.pickle ? [envelope.pickle] : []));
  const locations = stepLocations(document);

  describe(uri, () => {
    if (parseError) {
      test("parses", () => {
        throw new Error(`features/${uri}: ${parseError.message}`);
      });
      return;
    }
    const seen = new Map<string, number>();
    for (const pickle of pickles) {
      const tags = pickle.tags.map((tag) => tag.name);
      if (!isSelected(tags)) continue;
      // Outline examples share a name; number the repeats.
      const count = (seen.get(pickle.name) ?? 0) + 1;
      seen.set(pickle.name, count);
      const name = count > 1 ? `${pickle.name} (${count})` : pickle.name;
      const run = () => runPickle(uri, pickle, locations);
      if (tags.includes("@backlog") && !includeBacklog) test.skip(name, run);
      else test(name, run, SCENARIO_TIMEOUT_MS);
    }
  });
}

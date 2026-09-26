import * as NodeServices from "@effect/platform-node/NodeServices";
import { it, describe, expect } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";

import * as HalC2ProjectFileLoader from "./HalC2ProjectFileLoader.ts";

const TestLayer = Layer.empty.pipe(
  Layer.provideMerge(HalC2ProjectFileLoader.layer),
  Layer.provideMerge(NodeServices.layer),
);

const makeTempDir = Effect.gen(function* () {
  const fileSystem = yield* FileSystem.FileSystem;
  return yield* fileSystem.makeTempDirectoryScoped({
    prefix: "hal-c2-project-file-",
  });
});

const writeProjectFile = Effect.fn("writeProjectFile")(function* (
  cwd: string,
  contents: string,
  fileName = "hal-c2.json",
) {
  const fileSystem = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  yield* fileSystem.writeFileString(path.join(cwd, fileName), contents).pipe(Effect.orDie);
});

it.layer(TestLayer)("HalC2ProjectFileLoader", (it) => {
  describe("load", () => {
    it.effect("loads and decodes a valid hal-c2.json", () =>
      Effect.gen(function* () {
        const loader = yield* HalC2ProjectFileLoader.HalC2ProjectFileLoader;
        const cwd = yield* makeTempDir;
        yield* writeProjectFile(
          cwd,
          `{
            // JSONC is tolerated
            "iconPath": "assets/logo.svg",
            "scripts": [{ "name": "Dev", "command": "pnpm dev" }],
          }`,
        );

        const loaded = yield* loader.load(cwd);

        expect(Option.isSome(loaded)).toBe(true);
        if (Option.isSome(loaded)) {
          expect(loaded.value.iconPath).toBe("assets/logo.svg");
          expect(loaded.value.scripts).toEqual([{ name: "Dev", command: "pnpm dev" }]);
        }
      }),
    );

    it.effect("reads a pre-rename t3.json when hal-c2.json is missing", () =>
      Effect.gen(function* () {
        const loader = yield* HalC2ProjectFileLoader.HalC2ProjectFileLoader;
        const cwd = yield* makeTempDir;
        yield* writeProjectFile(cwd, `{ "iconPath": "legacy.svg" }`, "t3.json");

        const loaded = yield* loader.load(cwd);

        expect(Option.map(loaded, (file) => file.iconPath)).toEqual(Option.some("legacy.svg"));
      }),
    );

    it.effect("prefers hal-c2.json over t3.json", () =>
      Effect.gen(function* () {
        const loader = yield* HalC2ProjectFileLoader.HalC2ProjectFileLoader;
        const cwd = yield* makeTempDir;
        yield* writeProjectFile(cwd, `{ "iconPath": "legacy.svg" }`, "t3.json");
        yield* writeProjectFile(cwd, `{ "iconPath": "current.svg" }`);

        const loaded = yield* loader.load(cwd);

        expect(Option.map(loaded, (file) => file.iconPath)).toEqual(Option.some("current.svg"));
      }),
    );

    it.effect("returns none when hal-c2.json is missing", () =>
      Effect.gen(function* () {
        const loader = yield* HalC2ProjectFileLoader.HalC2ProjectFileLoader;
        const cwd = yield* makeTempDir;

        const loaded = yield* loader.load(cwd);

        expect(Option.isNone(loaded)).toBe(true);
      }),
    );

    it.effect("returns none for malformed JSON without failing", () =>
      Effect.gen(function* () {
        const loader = yield* HalC2ProjectFileLoader.HalC2ProjectFileLoader;
        const cwd = yield* makeTempDir;
        yield* writeProjectFile(cwd, "{ not json");

        const loaded = yield* loader.load(cwd);

        expect(Option.isNone(loaded)).toBe(true);
      }),
    );

    it.effect("returns none for schema-invalid files without failing", () =>
      Effect.gen(function* () {
        const loader = yield* HalC2ProjectFileLoader.HalC2ProjectFileLoader;
        const cwd = yield* makeTempDir;
        yield* writeProjectFile(cwd, '{ "scripts": [{ "name": "Dev" }] }');

        const loaded = yield* loader.load(cwd);

        expect(Option.isNone(loaded)).toBe(true);
      }),
    );
  });
});

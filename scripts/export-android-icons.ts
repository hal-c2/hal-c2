#!/usr/bin/env node

// Renders the Android launcher icon's foreground from the Icon Composer SVG sources.
//
// Icon Composer exports already contain a rounded-square silhouette, and Android masks
// the central 72dp of a 108dp adaptive canvas, so exporting them as a foreground produces
// a double-framed icon with the letters cropped by the mask. Instead the foreground is
// transparent and keeps the avatar inside the safe zone, over the background colour in
// apps/mobile-qt/android/res/values/colors.xml.

import * as NodeRuntime from "@effect/platform-node/NodeRuntime";
import * as NodeServices from "@effect/platform-node/NodeServices";
import * as Console from "effect/Console";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import sharp from "sharp";

// 108dp at xxxhdpi. Android scales it down for the other densities.
const ADAPTIVE_CANVAS = 432;
// Icon Composer's layer sources use a 128pt viewBox; the avatar in text.svg spans this box.
const MARK = { x: 20, y: 25.28, width: 88, height: 77.44 };
// Avatar width as a fraction of the 108dp canvas. The visible area is 72dp (66dp
// guaranteed), so 0.56 leaves the avatar at ~84% of the mask with room for the
// launcher's own zoom effects.
const MARK_FRACTION = 0.56;
const SVG_DENSITY = 300;
const OUTPUT = "apps/mobile-qt/android/res/mipmap-xxxhdpi/ic_launcher_foreground.png";

export class AndroidIconRenderError extends Schema.TaggedError<AndroidIconRenderError>()(
  "AndroidIconRenderError",
  { layer: Schema.String, cause: Schema.Defect() },
) {}

const markTransform = (size: number) => {
  const scale = (size * MARK_FRACTION) / MARK.width;
  const tx = (size - MARK.width * scale) / 2 - MARK.x * scale;
  const ty = (size - MARK.height * scale) / 2 - MARK.y * scale;
  return `translate(${tx.toFixed(3)} ${ty.toFixed(3)}) scale(${scale.toFixed(4)})`;
};

const canvasSvg = (size: number, inner: string) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" fill="none">${inner}</svg>`;

const rasterize = (layer: string, svg: string, size: number) =>
  Effect.tryPromise({
    try: () =>
      sharp(Buffer.from(svg), { density: SVG_DENSITY }).resize(size, size).png().toBuffer(),
    catch: (cause) => new AndroidIconRenderError({ layer, cause }),
  });

const renderForeground = Effect.fn("androidIcons.renderForeground")(function* (
  repositoryRoot: string,
  size: number,
) {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const text = yield* fs.readFileString(
    path.join(repositoryRoot, "assets", "prod", "app-icon.icon", "Assets", "text.svg"),
  );
  const body = text.replace(/^[\s\S]*?<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "");
  return yield* rasterize(
    "foreground",
    canvasSvg(size, `<g transform="${markTransform(size)}">${body}</g>`),
    size,
  );
});

const exportAndroidIcons = Effect.gen(function* () {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const repositoryRoot = path.resolve(import.meta.dirname, "..");
  const foreground = yield* renderForeground(repositoryRoot, ADAPTIVE_CANVAS);
  yield* fs.writeFile(path.join(repositoryRoot, OUTPUT), foreground);
  yield* Console.log(`wrote ${OUTPUT}`);
});

if (import.meta.main) {
  exportAndroidIcons.pipe(Effect.provide(NodeServices.layer), NodeRuntime.runMain);
}

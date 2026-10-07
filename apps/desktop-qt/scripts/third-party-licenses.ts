// @effect-diagnostics nodeBuiltinImport:off - Standalone build script, deliberately Effect-free.
/**
 * Writes the third-party license manifest a Qt client's Open source licenses
 * page reads (src/native/LicensesController).
 *
 * The desktop's holds the web app's packages, which the bricks' icons come
 * from (scripts/gen-icons.mjs), and the notices tagged `desktop-qt` in
 * third-party-licenses.config.json (Qt, the MC's runtime, Node.js).
 * stage-runtime.mjs writes it to <runtime>/licenses/; `vp run licenses` writes
 * the one a dev build reads, apps/desktop-qt/licenses/ (gitignored), without
 * fetching missing SPDX texts.
 *
 * The phone's (`--mobile`) holds the notices tagged `mobile-qt` and no
 * packages: an APK ships no JavaScript, and the icons have a notice of their
 * own there, so writing it needs no node_modules. The Android build compiles
 * it into the binary (apps/mobile-qt/cmake/Licenses.cmake).
 *
 * Usage: node third-party-licenses.ts <output> [--offline | --mobile]
 */
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import { generateThirdPartyLicenseManifest } from "../../../scripts/lib/third-party-licenses.ts";

const configFile = new URL("../../../third-party-licenses.config.json", import.meta.url);

async function writeManifest(
  output: string,
  input: Omit<Parameters<typeof generateThirdPartyLicenseManifest>[0], "configFile">,
): Promise<void> {
  const manifest = await generateThirdPartyLicenseManifest({ configFile, ...input });
  await NodeFSP.mkdir(NodePath.dirname(output), { recursive: true });
  await NodeFSP.writeFile(output, `${JSON.stringify(manifest)}\n`);
}

export async function writeDesktopLicenseManifest(output: string, offline: boolean): Promise<void> {
  await writeManifest(output, {
    packageManifests: [{ bundle: "web", path: new URL("../../web/package.json", import.meta.url) }],
    bundleName: "desktop-qt",
    allowMissingGeneratedNotices: offline,
  });
}

export async function writeMobileLicenseManifest(output: string): Promise<void> {
  await writeManifest(output, { packageManifests: [], bundleName: "mobile-qt" });
}

if (import.meta.main) {
  const output = process.argv[2];
  if (output === undefined) {
    throw new Error("Usage: third-party-licenses.ts <output> [--offline | --mobile]");
  }
  if (process.argv.includes("--mobile")) {
    await writeMobileLicenseManifest(NodePath.resolve(output));
  } else {
    await writeDesktopLicenseManifest(NodePath.resolve(output), process.argv.includes("--offline"));
  }
}

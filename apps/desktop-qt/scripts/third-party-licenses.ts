// @effect-diagnostics nodeBuiltinImport:off - Standalone build script, deliberately Effect-free.
/**
 * Writes the third-party license manifest the Qt desktop's Open source
 * licenses page reads (src/native/LicensesController): the web app's packages,
 * which the bricks' icons come from (scripts/gen-icons.mjs), and the notices
 * tagged `desktop-qt` in third-party-licenses.config.json (Qt, the MC's
 * runtime, Node.js).
 *
 * stage-runtime.mjs writes it to <runtime>/licenses/; `vp run licenses` writes
 * the one a dev build reads, apps/desktop-qt/licenses/ (gitignored), without
 * fetching missing SPDX texts.
 *
 * Usage: node third-party-licenses.ts <output> [--offline]
 */
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import { generateThirdPartyLicenseManifest } from "../../../scripts/lib/third-party-licenses.ts";

export async function writeDesktopLicenseManifest(output: string, offline: boolean): Promise<void> {
  const manifest = await generateThirdPartyLicenseManifest({
    configFile: new URL("../../../third-party-licenses.config.json", import.meta.url),
    packageManifests: [{ bundle: "web", path: new URL("../../web/package.json", import.meta.url) }],
    bundleName: "desktop-qt",
    allowMissingGeneratedNotices: offline,
  });
  await NodeFSP.mkdir(NodePath.dirname(output), { recursive: true });
  await NodeFSP.writeFile(output, `${JSON.stringify(manifest)}\n`);
}

if (import.meta.main) {
  const output = process.argv[2];
  if (output === undefined) throw new Error("Usage: third-party-licenses.ts <output> [--offline]");
  await writeDesktopLicenseManifest(NodePath.resolve(output), process.argv.includes("--offline"));
}

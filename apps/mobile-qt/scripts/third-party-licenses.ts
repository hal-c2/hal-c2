// @effect-diagnostics nodeBuiltinImport:off - Standalone build script, deliberately Effect-free.
/**
 * Writes the third-party license manifest the Qt client's Open source licenses
 * page reads (src/native/LicensesController).
 *
 * It holds the notices tagged `mobile-qt` in third-party-licenses.config.json
 * and no packages: an APK ships no JavaScript, so writing it needs no
 * node_modules. The Android build compiles it into the binary
 * (apps/mobile-qt/cmake/Licenses.cmake).
 *
 * Usage: node third-party-licenses.ts <output> [--mobile]
 */
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";

import { generateThirdPartyLicenseManifest } from "../../../scripts/lib/third-party-licenses.ts";

const configFile = new URL("../../../third-party-licenses.config.json", import.meta.url);

export async function writeMobileLicenseManifest(output: string): Promise<void> {
  const manifest = await generateThirdPartyLicenseManifest({
    configFile,
    packageManifests: [],
    bundleName: "mobile-qt",
  });
  await NodeFSP.mkdir(NodePath.dirname(output), { recursive: true });
  await NodeFSP.writeFile(output, `${JSON.stringify(manifest)}\n`);
}

if (import.meta.main) {
  const output = process.argv[2];
  if (output === undefined) {
    throw new Error("Usage: third-party-licenses.ts <output> [--mobile]");
  }
  await writeMobileLicenseManifest(NodePath.resolve(output));
}

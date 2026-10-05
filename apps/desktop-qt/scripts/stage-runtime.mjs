/**
 * Stages what the packaged hal-c2-qt runs next to the binary:
 *   host/*.ts       the desktop host, with the packages/shared modules it imports (Node built-ins only otherwise)
 *   hal-c2-mc/    the Elixir MC release (apps/server-ex/_build/prod/rel/hal_c2,
 *                   or HAL_C2_MC_RELEASE); the host runs its bin/hal_c2
 *   bin/node        the Node that runs the host and the MC's JavaScript sidecars
 *   licenses/       Node's LICENSE, and the third-party notices the licenses page
 *                   reads (third-party-licenses.ts)
 *
 * Usage: node stage-runtime.mjs <destination>
 */
import * as NodeFS from "node:fs";
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import { writeDesktopLicenseManifest } from "./third-party-licenses.ts";

const scriptDir = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const repoRoot = NodePath.resolve(scriptDir, "../../..");
const destinationArg = process.argv[2];
// oxlint-disable-next-line hal-c2/no-global-process-runtime -- Standalone packaging script has no Effect runtime.
const hostPlatform = NodeOS.platform();

if (destinationArg === undefined) {
  throw new Error("Usage: stage-runtime.mjs <destination>");
}

const destination = NodePath.resolve(destinationArg);
const hostDir = NodePath.join(repoRoot, "apps/desktop-qt/host");
const mcRelease = NodePath.resolve(
  process.env.HAL_C2_MC_RELEASE?.trim() ||
    NodePath.join(repoRoot, "apps/server-ex/_build/prod/rel/hal_c2"),
);
const nodePrefix = NodePath.resolve(NodePath.dirname(process.execPath), "..");
const nodeLicense = NodePath.join(nodePrefix, "LICENSE");
const nodeExecutableName = hostPlatform === "win32" ? "node.exe" : "node";

function requireFile(path, hint) {
  if (!NodeFS.existsSync(path)) throw new Error(`${path} is missing. ${hint}`);
}
requireFile(
  NodePath.join(mcRelease, "bin/hal_c2"),
  "Build it in apps/server-ex with `MIX_ENV=prod mix release`.",
);
requireFile(nodeLicense, "Run with a Node install that ships its LICENSE.");

// The staged host has no node_modules, so a module it takes from packages/shared is
// copied in beside it and imported from there. Anything else it imports must be a
// Node built-in or another host module.
const sharedImport = /from "@hal-c2\/shared\/(\w+)"/g;

async function stageHostModule(name) {
  const source = await NodeFSP.readFile(NodePath.join(hostDir, name), "utf8");
  const shared = [...source.matchAll(sharedImport)].map((match) => match[1]);
  await Promise.all(
    shared.map((module) =>
      NodeFSP.copyFile(
        NodePath.join(repoRoot, "packages/shared/src", `${module}.ts`),
        NodePath.join(destination, "host", `${module}.ts`),
      ),
    ),
  );
  const staged = source.replace(sharedImport, 'from "./$1.ts"');
  const foreign = staged.match(/from "(?!node:|\.\/)[^"]+"/);
  if (foreign) throw new Error(`host/${name} imports ${foreign[0]}, which the staged host lacks.`);
  await NodeFSP.writeFile(NodePath.join(destination, "host", name), staged);
}

const hostModules = (await NodeFSP.readdir(hostDir)).filter(
  (name) => name.endsWith(".ts") && !name.endsWith(".test.ts"),
);

await NodeFSP.rm(destination, { recursive: true, force: true });
await Promise.all([
  NodeFSP.mkdir(NodePath.join(destination, "host"), { recursive: true }),
  NodeFSP.mkdir(NodePath.join(destination, "bin"), { recursive: true }),
  NodeFSP.mkdir(NodePath.join(destination, "licenses/node"), { recursive: true }),
]);
await Promise.all([
  ...hostModules.map(stageHostModule),
  NodeFSP.cp(mcRelease, NodePath.join(destination, "hal-c2-mc"), {
    recursive: true,
    verbatimSymlinks: true,
  }),
  NodeFSP.copyFile(process.execPath, NodePath.join(destination, "bin", nodeExecutableName)),
  NodeFSP.copyFile(nodeLicense, NodePath.join(destination, "licenses/node/LICENSE")),
]);
await writeDesktopLicenseManifest(
  NodePath.join(destination, "licenses/third-party-licenses.json"),
  false,
);
if (hostPlatform !== "win32") {
  await NodeFSP.chmod(NodePath.join(destination, "bin", nodeExecutableName), 0o755);
}
// The host is plain ESM TypeScript run through Node's type stripping.
await NodeFSP.writeFile(
  NodePath.join(destination, "package.json"),
  `${JSON.stringify({ name: "hal-c2-qt-runtime", private: true, type: "module" }, null, 2)}\n`,
);

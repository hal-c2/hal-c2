/**
 * Stages what the packaged hal-c2-qt runs next to the binary:
 *   host/*.ts       the desktop host (Node built-ins only, no dependencies)
 *   web/            the built web app (apps/web/dist, or HAL_C2_WEB_DIST)
 *   hal-c2-node/    the Elixir node release (apps/server-ex/_build/prod/rel/hal_c2,
 *                   or HAL_C2_NODE_RELEASE); the host runs its bin/hal_c2
 *   bin/node        the Node that runs the host and the node's JavaScript sidecars
 *
 * Usage: node stage-runtime.mjs <destination>
 */
import * as NodeFS from "node:fs";
import * as NodeFSP from "node:fs/promises";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

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
const webDist = NodePath.resolve(
  process.env.HAL_C2_WEB_DIST?.trim() || NodePath.join(repoRoot, "apps/web/dist"),
);
const nodeRelease = NodePath.resolve(
  process.env.HAL_C2_NODE_RELEASE?.trim() ||
    NodePath.join(repoRoot, "apps/server-ex/_build/prod/rel/hal_c2"),
);
const nodePrefix = NodePath.resolve(NodePath.dirname(process.execPath), "..");
const nodeLicense = NodePath.join(nodePrefix, "LICENSE");
const nodeExecutableName = hostPlatform === "win32" ? "node.exe" : "node";

function requireFile(path, hint) {
  if (!NodeFS.existsSync(path)) throw new Error(`${path} is missing. ${hint}`);
}
requireFile(
  NodePath.join(webDist, "index.html"),
  "Build it with `vp run --filter @hal-c2/web build`.",
);
requireFile(
  NodePath.join(nodeRelease, "bin/hal_c2"),
  "Build it in apps/server-ex with `MIX_ENV=prod mix release`.",
);
requireFile(nodeLicense, "Run with a Node install that ships its LICENSE.");

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
  ...hostModules.map((name) =>
    NodeFSP.copyFile(NodePath.join(hostDir, name), NodePath.join(destination, "host", name)),
  ),
  NodeFSP.cp(webDist, NodePath.join(destination, "web"), { recursive: true }),
  NodeFSP.cp(nodeRelease, NodePath.join(destination, "hal-c2-node"), {
    recursive: true,
    verbatimSymlinks: true,
  }),
  NodeFSP.copyFile(process.execPath, NodePath.join(destination, "bin", nodeExecutableName)),
  NodeFSP.copyFile(nodeLicense, NodePath.join(destination, "licenses/node/LICENSE")),
]);
if (hostPlatform !== "win32") {
  await NodeFSP.chmod(NodePath.join(destination, "bin", nodeExecutableName), 0o755);
}
// The host is plain ESM TypeScript run through Node's type stripping.
await NodeFSP.writeFile(
  NodePath.join(destination, "package.json"),
  `${JSON.stringify({ name: "hal-c2-qt-runtime", private: true, type: "module" }, null, 2)}\n`,
);

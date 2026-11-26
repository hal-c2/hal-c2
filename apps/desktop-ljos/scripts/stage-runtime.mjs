/**
 * Stages what the packaged hal-c2-ljos runs next to the binary:
 *   hal-c2-mc/    the Elixir MC release (apps/server-ex/_build/prod/rel/hal_c2,
 *                   or HAL_C2_MC_RELEASE); the shell's own launcher runs its
 *                   bin/hal_c2, so no Node host is staged
 *   bin/node        the Node the MC runs its JavaScript sidecars on
 *   licenses/node/  Node's LICENSE; the app's own notices beside it come from
 *                   third-party-licenses.ts, which the release runs after this
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

await NodeFSP.rm(destination, { recursive: true, force: true });
await Promise.all([
  NodeFSP.mkdir(NodePath.join(destination, "bin"), { recursive: true }),
  NodeFSP.mkdir(NodePath.join(destination, "licenses/node"), { recursive: true }),
]);
await Promise.all([
  NodeFSP.cp(mcRelease, NodePath.join(destination, "hal-c2-mc"), {
    recursive: true,
    verbatimSymlinks: true,
  }),
  NodeFSP.copyFile(process.execPath, NodePath.join(destination, "bin", nodeExecutableName)),
  NodeFSP.copyFile(nodeLicense, NodePath.join(destination, "licenses/node/LICENSE")),
]);
if (hostPlatform !== "win32") {
  await NodeFSP.chmod(NodePath.join(destination, "bin", nodeExecutableName), 0o755);
}

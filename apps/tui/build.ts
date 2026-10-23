import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

// Bundles the terminal client into dist/. It stamps the client's release into the
// bundle from the MC's (`HAL_C2_MC_VERSION`, else apps/server-ex/VERSION, the same
// choice as the MC's mix.exs), so a server behind this client is offered an update.

const root = import.meta.dir;
const version =
  process.env.HAL_C2_MC_VERSION?.trim() ||
  NodeFS.readFileSync(NodePath.join(root, "../server-ex/VERSION"), "utf8").trim();

const result = await Bun.build({
  entrypoints: [NodePath.join(root, "src/index.ts")],
  outdir: NodePath.join(root, "dist"),
  target: "bun",
  external: ["@opentui/core", "sharp"],
  define: { __HAL_C2_APP_VERSION__: JSON.stringify(version) },
});
if (!result.success) {
  for (const log of result.logs) process.stderr.write(`${log.message}\n`);
  process.exit(1);
}

NodeFS.rmSync(NodePath.join(root, "dist/qml"), { recursive: true, force: true });
NodeFS.cpSync(NodePath.join(root, "qml"), NodePath.join(root, "dist/qml"), { recursive: true });

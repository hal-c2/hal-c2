// @effect-diagnostics nodeBuiltinImport:off - Checks files committed to the repository.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";

import { PluginManifest, pluginManifestJsonSchema } from "@hal-c2/contracts";
import * as Schema from "effect/Schema";
import { describe, expect, it } from "vite-plus/test";

const repo = NodePath.resolve(import.meta.dirname, "../../..");
const decodeManifest = Schema.decodeUnknownSync(PluginManifest);

describe("plugin packages in the repository", () => {
  it("each manifest decodes and names its own directory", () => {
    const root = NodePath.join(repo, "plugins");
    const manifests = NodeFS.existsSync(root)
      ? NodeFS.readdirSync(root)
          .map((name) => NodePath.join(root, name, "plugin.json"))
          .filter((file) => NodeFS.existsSync(file))
      : [];
    for (const file of manifests) {
      const manifest = decodeManifest(JSON.parse(NodeFS.readFileSync(file, "utf8")));
      expect(manifest.id).toBe(NodePath.basename(NodePath.dirname(file)));
    }
  });

  // Plugin authors outside this repository point `$schema` at this file.
  it("plugin.schema.json is the manifest contract", () => {
    const published = NodePath.join(repo, "packages/contracts/plugin.schema.json");
    if (NodeProcess.env.UPDATE_PLUGIN_SCHEMA === "1") {
      NodeFS.writeFileSync(published, `${JSON.stringify(pluginManifestJsonSchema, null, 2)}\n`);
    }
    expect(JSON.parse(NodeFS.readFileSync(published, "utf8"))).toEqual(pluginManifestJsonSchema);
  });
});

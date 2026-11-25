// @effect-diagnostics nodeBuiltinImport:off - Standalone build script, deliberately Effect-free.
/**
 * Writes the third-party license manifest desktop-ljos's Open source
 * licenses page reads (shell/src/controllers/licenses.rs), from this app's
 * own build instead of desktop-qt's (#1661 step 3):
 *
 * - the Rust crates the shell links, from `cargo metadata --locked` over
 *   apps/desktop-ljos's Cargo.lock (the normal dependencies of the
 *   workspace's crates, first-party path crates of this repo left out). A
 *   crate's notice is the license file at its root (or its workspace's);
 *   a crate that ships none gets the SPDX text of its license, as the
 *   generated custom notices get theirs. Target-specific crates of every
 *   platform are listed, not only the building platform's.
 * - the packages of the Cursor sidecar the staged MC ships, and the
 *   notices tagged `desktop-ljos` in third-party-licenses.config.json
 *   (CEF/Chromium, the MC's Erlang and Elixir, Node.js, the bricks'
 *   icons, the Snap Shot sounds), through scripts/lib as desktop-qt's
 *   manifest is made. Ljós itself arrives with the crates; this build
 *   links no Qt, so it carries no Qt notice.
 *
 * `mise run desktop-ljos:licenses` writes the one a dev build reads,
 * apps/desktop-ljos/licenses/ (gitignored), without fetching missing
 * SPDX texts; the release writes it over stage-runtime's desktop-qt
 * manifest in share/hal-c2/licenses/.
 *
 * Usage: node third-party-licenses.ts <output> [--offline]
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFSP from "node:fs/promises";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import {
  generateThirdPartyLicenseManifest,
  spdxNoticeText,
  type ThirdPartyLicenseEntry,
  type ThirdPartyLicenseManifest,
} from "../../../scripts/lib/third-party-licenses.ts";

const configFile = new URL("../../../third-party-licenses.config.json", import.meta.url);
const scriptDir = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
const appDir = NodePath.resolve(scriptDir, "..");
const repoRoot = NodePath.resolve(appDir, "../..");
const BUNDLE = "desktop-ljos";

interface CargoPackage {
  readonly id: string;
  readonly name: string;
  readonly version: string;
  readonly license?: string | null;
  readonly license_file?: string | null;
  readonly homepage?: string | null;
  readonly repository?: string | null;
  readonly manifest_path: string;
  readonly source?: string | null;
}

interface CargoMetadata {
  readonly packages: ReadonlyArray<CargoPackage>;
  readonly workspace_members: ReadonlyArray<string>;
  readonly resolve?: {
    readonly nodes: ReadonlyArray<{
      readonly id: string;
      readonly deps: ReadonlyArray<{
        readonly pkg: string;
        readonly dep_kinds: ReadonlyArray<{ readonly kind?: string | null }>;
      }>;
    }>;
  } | null;
}

const NOTICE_FILE = /^(?:licen[cs]e|copying|notice)(?:[._-].*)?$/i;

function cargoMetadata(offline: boolean): CargoMetadata {
  const args = [
    "metadata",
    "--locked",
    "--format-version",
    "1",
    "--manifest-path",
    NodePath.join(appDir, "Cargo.toml"),
    ...(offline ? ["--offline"] : []),
  ];
  const out = NodeChildProcess.execFileSync("cargo", args, {
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", "inherit"],
  });
  return JSON.parse(out.toString("utf8")) as CargoMetadata;
}

/** The workspace's normal (not dev, not build-only) dependencies. */
function reachable(metadata: CargoMetadata): ReadonlyArray<CargoPackage> {
  const byId = new Map(metadata.packages.map((p) => [p.id, p]));
  const nodes = new Map((metadata.resolve?.nodes ?? []).map((n) => [n.id, n]));
  const workspace = new Set(metadata.workspace_members);
  const seen = new Set<string>();
  const stack = [...workspace];
  while (stack.length > 0) {
    const id = stack.pop()!;
    if (seen.has(id)) continue;
    seen.add(id);
    for (const dep of nodes.get(id)?.deps ?? []) {
      if (dep.dep_kinds.some((kind) => kind.kind === null || kind.kind === undefined)) {
        stack.push(dep.pkg);
      }
    }
  }
  return [...seen]
    .filter((id) => !workspace.has(id))
    .map((id) => byId.get(id))
    .filter((p): p is CargoPackage => p !== undefined)
    // A path crate of this repo (native/syntax) is first-party, as
    // @hal-c2/ packages are to the JavaScript manifest.
    .filter((p) => !(p.source === null && p.manifest_path.startsWith(repoRoot + NodePath.sep)))
    .sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));
}

async function noticeFilesIn(directory: string): Promise<ReadonlyArray<string>> {
  const entries = await NodeFSP.readdir(directory, { withFileTypes: true }).catch(() => []);
  return entries
    .filter((entry) => entry.isFile() && NOTICE_FILE.test(entry.name))
    .map((entry) => NodePath.join(directory, entry.name))
    .sort((a, b) => a.localeCompare(b));
}

/** A crate's own notice text: its root's license files, its declared
 * license file, or its workspace root's (a git crate such as a Ljós one
 * keeps its LICENSE at the checkout's root). */
async function crateNoticeText(pkg: CargoPackage): Promise<string | null> {
  const root = NodePath.dirname(pkg.manifest_path);
  let files = await noticeFilesIn(root);
  if (files.length === 0 && pkg.license_file) {
    files = [NodePath.join(root, pkg.license_file)];
  }
  let directory = root;
  for (let up = 0; files.length === 0 && up < 3; up++) {
    directory = NodePath.dirname(directory);
    const workspaceManifest = await NodeFSP.stat(NodePath.join(directory, "Cargo.toml")).catch(
      () => null,
    );
    if (workspaceManifest?.isFile()) files = await noticeFilesIn(directory);
  }
  const sections: string[] = [];
  for (const file of files) {
    const text = (await NodeFSP.readFile(file, "utf8").catch(() => "")).trim();
    if (text.length > 0) sections.push(text);
  }
  return sections.length > 0 ? sections.join("\n\n---\n\n") : null;
}

/** The SPDX ids of a license expression ("MIT OR Apache-2.0",
 * "Apache-2.0 WITH LLVM-exception", the old "MIT/Apache-2.0"). */
function spdxIds(license: string): ReadonlyArray<string> {
  const ids: string[] = [];
  let skipNext = false;
  for (const token of license.replace(/[()]/g, " ").split(/\s+/)) {
    if (token.length === 0) continue;
    if (skipNext) {
      skipNext = false;
      continue;
    }
    if (token === "WITH") {
      skipNext = true;
      continue;
    }
    if (token === "AND" || token === "OR") continue;
    for (const part of token.split("/")) {
      if (part.length > 0) ids.push(part.replace(/\++$/, ""));
    }
  }
  return ids;
}

async function crateEntries(offline: boolean): Promise<ReadonlyArray<ThirdPartyLicenseEntry>> {
  const entries: ThirdPartyLicenseEntry[] = [];
  const failures: string[] = [];
  for (const pkg of reachable(cargoMetadata(offline))) {
    const license = pkg.license?.trim() || null;
    if (!license && !pkg.license_file) {
      failures.push(`${pkg.name}@${pkg.version} declares no license in its Cargo.toml.`);
      continue;
    }
    let noticeText = await crateNoticeText(pkg);
    if (noticeText === null && license !== null) {
      noticeText = await spdxNoticeText(configFile, spdxIds(license), offline);
    }
    if (noticeText === null) {
      if (offline) continue;
      failures.push(
        `${pkg.name}@${pkg.version} ships no license file and no SPDX text could be generated for "${license ?? pkg.license_file}".`,
      );
      continue;
    }
    entries.push({
      bundles: [BUNDLE],
      kind: "package",
      license: license ?? "See notice",
      name: pkg.name,
      noticeText,
      sourceUrl: pkg.repository?.trim() || pkg.homepage?.trim() || null,
      version: pkg.version,
    });
  }
  if (failures.length > 0) {
    throw new Error(
      `desktop-ljos license generation found ${String(failures.length)} invalid crate notice(s):\n${failures.map((f) => `- ${f}`).join("\n")}`,
    );
  }
  return entries;
}

export async function writeDesktopLjosLicenseManifest(
  output: string,
  offline: boolean,
): Promise<void> {
  const [base, crates] = await Promise.all([
    generateThirdPartyLicenseManifest({
      configFile,
      packageManifests: [
        {
          bundle: BUNDLE,
          path: new URL("../../../packages/cursor-acp/package.json", import.meta.url),
        },
      ],
      bundleName: BUNDLE,
      allowMissingGeneratedNotices: offline,
    }),
    crateEntries(offline),
  ]);
  const entries = [...base.entries, ...crates].sort(
    (a, b) =>
      a.name.localeCompare(b.name) ||
      (a.version ?? "").localeCompare(b.version ?? "") ||
      a.kind.localeCompare(b.kind),
  );
  const identities = new Set<string>();
  for (const entry of entries) {
    const identity = JSON.stringify([entry.kind, entry.name, entry.version]);
    if (identities.has(identity)) {
      throw new Error(
        `desktop-ljos license generation found a duplicate ${entry.kind} notice for ${entry.name}${entry.version ? `@${entry.version}` : ""}.`,
      );
    }
    identities.add(identity);
  }
  const manifest: ThirdPartyLicenseManifest = { schemaVersion: 1, entries };
  await NodeFSP.mkdir(NodePath.dirname(output), { recursive: true });
  await NodeFSP.writeFile(output, `${JSON.stringify(manifest)}\n`);
}

if (import.meta.main) {
  const output = process.argv[2];
  if (output === undefined) {
    throw new Error("Usage: third-party-licenses.ts <output> [--offline]");
  }
  await writeDesktopLjosLicenseManifest(
    NodePath.resolve(output),
    process.argv.includes("--offline"),
  );
}

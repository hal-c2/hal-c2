/**
 * Dev loop for the Qt shell:
 *   1. configure + build apps/desktop-qt with CMake (incremental after the first run)
 *   2. mint a pairing link for the Elixir node `mise run node` runs (`mix hal_c2.pair`)
 *   3. launch hal-c2-qt --url <pairing link>; its desktop host serves the built
 *      web app (apps/web/dist) and opens it paired with that node
 *
 * Flags the script consumes:
 *   --home-dir <dir>   the shell's HAL-C2 home (HAL_C2_HOME for hal-c2-qt): where it
 *                      rices from (<dir>/config/shell) and keeps its web profile, and
 *                      the home a --standalone node gets. Defaults to the checkout's
 *                      .hal-c2 (the shell has no development profile, so it does not
 *                      share `mise run node`'s hal-c2-dev).
 *   --url <url>        skip pairing and attach to this URL (a node pairing link, or
 *                      any page to load as it is)
 *   --standalone       no pairing: the shell starts its own node from source, as the
 *                      installed app does. Do not run it next to `mise run node` on
 *                      the same home.
 *   --release          build with CMAKE_BUILD_TYPE=Release (no disk QML loading)
 *   --configure-only   stop after the CMake build
 *   --help
 * Every other argument is passed through to the hal-c2-qt binary, so the
 * shell's own flags (--config-dir, --qml-dir, --screenshot, --action, ...)
 * work from `mise run desktop` too. A bare `--` forwards the rest verbatim.
 * Environment:
 *   QT_PREFIX / CMAKE_PREFIX_PATH   where Qt 6 lives (defaults: qmake6 on PATH, then Homebrew)
 *   HAL_C2_NODE_PORT                the running node's port (default 3780)
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

const appDir = NodePath.resolve(NodePath.dirname(NodeURL.fileURLToPath(import.meta.url)), "..");
const checkoutDir = NodePath.resolve(appDir, "../..");
const nodeDir = NodePath.join(checkoutDir, "apps/server-ex");

function fail(message) {
  process.stderr.write(`[dev-qt] ${message}\n`);
  process.exit(1);
}

function usage() {
  process.stdout.write(
    [
      "Usage: mise run desktop [--home-dir <dir>] [--url <url> | --standalone] [--release] [--configure-only] [-- <hal-c2-qt args>]",
      "",
      "  --home-dir <dir>   the shell's HAL-C2 home (default: the checkout's .hal-c2)",
      "  --url <url>        attach to this node pairing link (or load this page) instead of pairing",
      "  --standalone       start the shell's own node from source instead of pairing with `mise run node`",
      "  --release          Release build (no disk QML loading)",
      "  --configure-only   build, do not launch",
      "",
      "Anything else is forwarded to hal-c2-qt (--config-dir, --qml-dir, --screenshot, --action, ...).",
      "",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const options = {
    configureOnly: false,
    release: false,
    standalone: false,
    url: undefined,
    homeDir: undefined,
  };
  const shellArgs = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const takeValue = () => {
      const value = argv[index + 1];
      if (value === undefined) fail(`${arg} needs a value`);
      index += 1;
      return value;
    };
    if (arg === "--") {
      shellArgs.push(...argv.slice(index + 1));
      break;
    } else if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    } else if (arg === "--configure-only") {
      options.configureOnly = true;
    } else if (arg === "--standalone") {
      options.standalone = true;
    } else if (arg === "--release") {
      options.release = true;
    } else if (arg === "--url") {
      options.url = takeValue();
    } else if (arg.startsWith("--url=")) {
      options.url = arg.slice("--url=".length);
    } else if (arg === "--home-dir") {
      options.homeDir = takeValue();
    } else if (arg.startsWith("--home-dir=")) {
      options.homeDir = arg.slice("--home-dir=".length);
    } else {
      shellArgs.push(arg);
    }
  }
  return { options, shellArgs };
}

const { options, shellArgs } = parseArgs(process.argv.slice(2));
const buildType = options.release ? "Release" : "Debug";
const buildDir = NodePath.join(appDir, "build", buildType.toLowerCase());

function run(command, commandArgs) {
  const result = NodeChildProcess.spawnSync(command, commandArgs, {
    cwd: appDir,
    stdio: "inherit",
  });
  if (result.error) fail(`${command} failed: ${result.error.message}`);
  if (result.status !== 0)
    fail(`${command} ${commandArgs.join(" ")} exited with ${String(result.status)}`);
}

function capture(command, commandArgs) {
  const result = NodeChildProcess.spawnSync(command, commandArgs, { encoding: "utf8" });
  if (result.error || result.status !== 0) return undefined;
  return result.stdout.trim();
}

function resolveQtPrefix() {
  const fromEnv = process.env.QT_PREFIX ?? process.env.CMAKE_PREFIX_PATH;
  if (fromEnv) return fromEnv;
  const fromQmake =
    capture("qmake6", ["-query", "QT_INSTALL_PREFIX"]) ??
    capture("qmake", ["-query", "QT_INSTALL_PREFIX"]);
  if (fromQmake) return fromQmake;
  const fromBrew = capture("brew", ["--prefix", "qt"]);
  if (fromBrew) return fromBrew;
  return fail(
    "Qt 6 not found. Set QT_PREFIX to the Qt install (e.g. /opt/homebrew/opt/qt or ~/Qt/6.11.1/gcc_64).",
  );
}

function expandHome(raw) {
  const trimmed = raw.trim();
  if (trimmed === "~" || trimmed.startsWith("~/")) {
    return NodePath.join(NodeOS.homedir(), trimmed.slice(1));
  }
  return trimmed;
}

/** `--home-dir`, else the checkout's `.hal-c2`. */
function resolveRoot() {
  const explicit = options.homeDir?.trim() ?? "";
  return explicit.length > 0
    ? NodePath.resolve(expandHome(explicit))
    : NodePath.join(checkoutDir, ".hal-c2");
}

function build() {
  // build.ninja, not CMakeCache.txt: a configure that failed (a missing Qt
  // module, say) leaves the cache behind, and must run again next time.
  if (!NodeFS.existsSync(NodePath.join(buildDir, "build.ninja"))) {
    const qtPrefix = resolveQtPrefix();
    process.stderr.write(`[dev-qt] configuring (${buildType}) with Qt at ${qtPrefix}\n`);
    run("cmake", [
      "-S",
      appDir,
      "-B",
      buildDir,
      "-G",
      "Ninja",
      `-DCMAKE_BUILD_TYPE=${buildType}`,
      `-DCMAKE_PREFIX_PATH=${qtPrefix}`,
    ]);
  }
  run("cmake", ["--build", buildDir]);
}

function binaryPath() {
  // macOS bundle, plain executable, Windows executable: whichever this build produced.
  const candidates = [
    NodePath.join(buildDir, "hal-c2-qt.app/Contents/MacOS/hal-c2-qt"),
    NodePath.join(buildDir, "hal-c2-qt"),
    NodePath.join(buildDir, "hal-c2-qt.exe"),
  ];
  const found = candidates.find((candidate) => NodeFS.existsSync(candidate));
  return found ?? fail(`built binary not found under ${buildDir}`);
}

/** The running node's address, as `mix hal_c2.pair` and `mise run node` resolve it. */
function nodeOrigin() {
  const port = process.env.HAL_C2_NODE_PORT?.trim() || "3780";
  return `http://127.0.0.1:${port}`;
}

async function nodeIsRunning(origin) {
  try {
    const response = await fetch(new URL("/.well-known/hal-c2/environment", origin), {
      signal: AbortSignal.timeout(2_000),
    });
    const descriptor = await response.json();
    return typeof descriptor.orchestrationProtocolVersion === "number";
  } catch {
    return false;
  }
}

/** A one-time pairing link (5 minutes) for the node `mise run node` runs. */
async function pairWithNode() {
  const origin = nodeOrigin();
  if (!(await nodeIsRunning(origin))) {
    return fail(
      `no node answers at ${origin}. Start \`mise run node\` in another terminal first (set HAL_C2_NODE_PORT if it runs elsewhere), pass --url <pairing link>, or use --standalone.`,
    );
  }
  const result = NodeChildProcess.spawnSync("mix", ["hal_c2.pair", origin], {
    cwd: nodeDir,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  });
  const url = result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => /^https?:\/\/\S+[?#]token=/.test(line));
  return url ?? fail(`mix hal_c2.pair printed no pairing link (exit ${String(result.status)}).`);
}

build();
if (options.configureOnly) process.exit(0);

const root = resolveRoot();
const url = options.standalone ? undefined : (options.url ?? (await pairWithNode()));
const binary = binaryPath();
const binaryArgs = [...(url === undefined ? [] : ["--url", url]), ...shellArgs];
process.stderr.write(`[dev-qt] root ${root}\n`);
process.stderr.write(
  `[dev-qt] launching ${binary} ${url === undefined ? "(standalone)" : "--url <pairing link>"}\n`,
);
const child = NodeChildProcess.spawn(binary, binaryArgs, {
  stdio: "inherit",
  cwd: appDir,
  env: { ...process.env, HAL_C2_HOME: root },
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => child.kill(signal));
}
child.on("exit", (code) => process.exit(code ?? 0));

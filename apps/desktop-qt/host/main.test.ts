// @effect-diagnostics nodeBuiltinImport:off globalFetch:off - Drives the real host process against a fake MC on disk.
/**
 * Mirrors features/desktop/shell-host.feature: each `it` is named after the
 * scenario it covers. The host (main.ts) runs as the shell runs it; the MC is
 * a fake release (`bin/hal_c2 start`) that reads the bootstrap line, serves the
 * descriptor and `/oauth/token`, and records how it was started.
 */
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeHttp from "node:http";
import * as NodeNet from "node:net";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeReadline from "node:readline";
import * as NodeURL from "node:url";
import { afterEach, describe, expect, it } from "vite-plus/test";

import { mcDataDir, resolveMcLaunch, startMc } from "./elixirMc.ts";

const hostEntry = NodeURL.fileURLToPath(new URL("./main.ts", import.meta.url));
const nodeBin = process.execPath;

const FAKE_MC = String.raw`
import * as fs from "node:fs";
import * as http from "node:http";
import * as path from "node:path";

const dir = path.dirname(path.dirname(new URL(import.meta.url).pathname));
const input = fs.readFileSync(0, "utf8");
const bootstrap = process.env.HAL_C2_BOOTSTRAP_STDIN === "1" ? JSON.parse(input.split("\n")[0]) : {};
fs.writeFileSync(path.join(dir, "record.json"), JSON.stringify({
  argv: process.argv.slice(2),
  bootstrapStdin: process.env.HAL_C2_BOOTSTRAP_STDIN,
  nodeCommand: process.env.HAL_C2_NODE_COMMAND,
  environment: Object.values(process.env),
  bootstrap,
}));
if (process.env.FAKE_MC_FAIL) {
  process.stderr.write("fake MC: boom\n");
  process.exit(Number(process.env.FAKE_MC_FAIL));
}
const home = bootstrap.halC2Home ?? dir;
fs.mkdirSync(home, { recursive: true });
// HalC2.Web writes its access token at boot, under the home or the XDG data directory.
// The tests always point XDG_DATA_HOME at a temporary directory.
const dataDir = bootstrap.halC2Home
  ? path.join(home, "data", "elixir")
  : path.join(process.env.XDG_DATA_HOME ?? dir, "hal-c2", "elixir");
fs.mkdirSync(dataDir, { recursive: true });
if (!fs.existsSync(path.join(dataDir, "access-token")))
  fs.writeFileSync(path.join(dataDir, "access-token"), "mc-access-" + Math.random().toString(36).slice(2) + "\n");
const idFile = path.join(home, "environment-id");
if (!fs.existsSync(idFile)) fs.writeFileSync(idFile, "env-" + Math.random().toString(36).slice(2));
const environmentId = fs.readFileSync(idFile, "utf8");
const server = http.createServer((req, res) => {
  res.setHeader("access-control-allow-origin", "*");
  if (req.url === "/.well-known/hal-c2/environment") {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ environmentId, label: "Fake", orchestrationProtocolVersion: 3 }));
    return;
  }
  if (req.method === "POST" && req.url === "/oauth/token") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const params = new URLSearchParams(body);
      const ok = params.get("subject_token") === "pairing-token";
      res.statusCode = ok ? 200 : 400;
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(ok ? { access_token: "access", token_type: "Bearer", scope: "admin" } : { error: "invalid_grant" }));
    });
    return;
  }
  res.statusCode = 404;
  res.end();
});
server.listen(bootstrap.port, bootstrap.host, () => console.log("listening"));
process.on("SIGTERM", () => {
  fs.writeFileSync(path.join(dir, "stopped"), "");
  process.exit(0);
});
`;

const directories: string[] = [];
const cleanups: Array<() => void> = [];

function temporaryDirectory(): string {
  const path = NodeFS.mkdtempSync(NodePath.join(NodeOS.tmpdir(), "hal-c2-qt-host-"));
  directories.push(path);
  return path;
}

afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
  for (const directory of directories.splice(0))
    NodeFS.rmSync(directory, { recursive: true, force: true });
});

/** A fake MC release: `<dir>/bin/hal_c2`, recording to `<dir>/record.json`. */
function fakeRelease(): string {
  const dir = temporaryDirectory();
  NodeFS.mkdirSync(NodePath.join(dir, "bin"));
  NodeFS.writeFileSync(NodePath.join(dir, "bin/hal_c2"), `#!${nodeBin}\n${FAKE_MC}`, {
    mode: 0o755,
  });
  return dir;
}

interface McRecord {
  readonly argv: string[];
  readonly bootstrapStdin: string | undefined;
  readonly nodeCommand: string | undefined;
  readonly environment: string[];
  readonly bootstrap: {
    readonly port: number;
    readonly host: string;
    readonly halC2Home?: string;
  };
}

function readRecord(release: string): McRecord | undefined {
  const file = NodePath.join(release, "record.json");
  return NodeFS.existsSync(file)
    ? (JSON.parse(NodeFS.readFileSync(file, "utf8")) as McRecord)
    : undefined;
}

async function freePort(): Promise<number> {
  const server = NodeNet.createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as NodeNet.AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

/** Holds `port` (or any free port) until the test ends. */
async function occupy(port = 0): Promise<number | undefined> {
  const server = NodeNet.createServer();
  const listening = await new Promise<boolean>((resolve) => {
    server.once("error", () => resolve(false));
    server.listen(port, "127.0.0.1", () => resolve(true));
  });
  if (!listening) return undefined;
  cleanups.push(() => server.close());
  return (server.address() as NodeNet.AddressInfo).port;
}

type HostMessage =
  | { readonly type: "ready"; readonly mc: { readonly origin: string; readonly token: string } }
  | { readonly type: "error"; readonly message: string }
  | { readonly type: "exit"; readonly code: number | null };

interface Host {
  readonly message: Promise<HostMessage>;
  readonly exited: Promise<number | null>;
  quit(): Promise<number | null>;
}

function startHost(input: {
  readonly args?: ReadonlyArray<string>;
  readonly env?: Record<string, string | undefined>;
}): Host {
  const child = NodeChildProcess.spawn(nodeBin, [hostEntry, ...(input.args ?? [])], {
    stdio: ["pipe", "pipe", "pipe"],
    env: {
      ...process.env,
      HAL_C2_MC_PORT: undefined,
      HAL_C2_HOME: undefined,
      HAL_C2_MC_HOME: undefined,
      // Never the user's own data or state directory.
      XDG_DATA_HOME: temporaryDirectory(),
      XDG_STATE_HOME: temporaryDirectory(),
      HAL_C2_MC_RELEASE: undefined,
      ...input.env,
    },
  });
  child.stderr.resume();
  const exited = new Promise<number | null>((resolve) => child.once("exit", resolve));
  const message = new Promise<HostMessage>((resolve, reject) => {
    NodeReadline.createInterface({ input: child.stdout }).once("line", (line) =>
      resolve(JSON.parse(line) as HostMessage),
    );
    void exited.then(() => reject(new Error("host exited without a message")));
  });
  cleanups.push(() => child.kill("SIGKILL"));
  return {
    message,
    exited,
    quit: () => {
      child.stdin.end();
      return exited;
    },
  };
}

/** Where the host told the shell's own client to connect. */
async function ready(host: Host) {
  const message = await host.message;
  if (message.type !== "ready") throw new Error(`expected ready, got ${JSON.stringify(message)}`);
  return message.mc;
}

async function errorMessage(host: Host): Promise<string> {
  const message = await host.message;
  if (message.type !== "error") throw new Error(`expected error, got ${JSON.stringify(message)}`);
  return message.message;
}

/** A standalone launch against a fake release on free ports. */
async function standalone(
  options: {
    readonly release?: string;
    readonly home?: string;
    readonly env?: Record<string, string>;
  } = {},
) {
  const release = options.release ?? fakeRelease();
  const host = startHost({
    args: options.home === undefined ? [] : [`--base-dir=${options.home}`],
    env: {
      HAL_C2_MC_RELEASE: release,
      HAL_C2_MC_PORT: String(await freePort()),
      ...options.env,
    },
  });
  return { host, release, mc: await ready(host) };
}

async function descriptorOf(origin: string): Promise<{ environmentId: string }> {
  const response = await fetch(new URL("/.well-known/hal-c2/environment", origin));
  return (await response.json()) as { environmentId: string };
}

/** A fake MC the test starts itself, as `mise run mc` would. */
async function runningMc() {
  const release = fakeRelease();
  const port = await freePort();
  const child = NodeChildProcess.spawn(NodePath.join(release, "bin/hal_c2"), ["start"], {
    env: { ...process.env, HAL_C2_BOOTSTRAP_STDIN: "1", XDG_DATA_HOME: temporaryDirectory() },
    stdio: ["pipe", "pipe", "inherit"],
  });
  cleanups.push(() => child.kill("SIGKILL"));
  child.stdin.end(`${JSON.stringify({ port, host: "127.0.0.1" })}\n`);
  await new Promise((resolve) =>
    NodeReadline.createInterface({ input: child.stdout }).once("line", resolve),
  );
  return { origin: `http://127.0.0.1:${port}`, release };
}

/** The hal-c2-dev profile's MC directories under temporary XDG data and state homes. */
function devMcDirs(xdg: { readonly data: string; readonly state: string }) {
  const dirs = {
    data: NodePath.join(xdg.data, "hal-c2-dev", "elixir"),
    state: NodePath.join(xdg.state, "hal-c2-dev", "elixir"),
  };
  NodeFS.mkdirSync(dirs.data, { recursive: true });
  NodeFS.mkdirSync(dirs.state, { recursive: true });
  return dirs;
}

/** A runtime record as HalC2.RuntimeRecord writes it, for a process that is alive. */
function writeRuntimeRecord(stateDir: string, origin: string): void {
  NodeFS.writeFileSync(
    NodePath.join(stateDir, "server-runtime.json"),
    JSON.stringify({ origin, pid: process.pid, port: Number(new URL(origin).port) }),
  );
}

// oxlint-disable-next-line hal-c2/no-global-process-runtime -- The skip decision needs the real host, outside any Effect runtime.
describe.skipIf(NodeOS.platform() === "win32")("The desktop app runs its own MC", () => {
  describe("Starting the desktop app starts its MC and connects to it", () => {
    it("Starting the desktop app starts an MC with the desktop's HAL-C2 home", async () => {
      const home = temporaryDirectory();
      const { release, host } = await standalone({ home });
      const record = readRecord(release);

      expect(record?.bootstrap.halC2Home).toBe(home);
      expect(record?.bootstrapStdin).toBe("1");
      expect(record?.argv).toEqual(["start"]);
      await host.quit();
    });

    it("The desktop's own client is given the MC and its access token", async () => {
      const home = temporaryDirectory();
      const { release, host, mc } = await standalone({ home });
      const record = readRecord(release);
      const accessToken = NodeFS.readFileSync(
        NodePath.join(home, "data/elixir/access-token"),
        "utf8",
      ).trim();

      expect(mc).toEqual({
        origin: `http://127.0.0.1:${record?.bootstrap.port}`,
        token: accessToken,
      });
      await host.quit();
    });

    it("A development shell does not start an MC release without a home of its own", async () => {
      const release = fakeRelease();
      const env = {
        HAL_C2_MC_RELEASE: release,
        HAL_C2_MC_PORT: String(await freePort()),
        // Neither is a home the shell chose.
        HAL_C2_HOME: temporaryDirectory(),
        HAL_C2_MC_HOME: temporaryDirectory(),
      };
      const refused = startHost({ args: ["--dev"], env });

      expect(await errorMessage(refused)).toContain("--home-dir");
      expect(readRecord(release)).toBeUndefined();

      const home = temporaryDirectory();
      const host = startHost({ args: ["--dev", `--base-dir=${home}`], env });
      await ready(host);
      expect(readRecord(release)?.bootstrap.halC2Home).toBe(home);
      await host.quit();
    });

    it("An MC home the MC would not use stops the start", async () => {
      const release = fakeRelease();
      const home = temporaryDirectory();

      for (const mcHome of ["scratch/mc", NodePath.join(home, ".t3", "elixir")]) {
        const host = startHost({
          env: { HAL_C2_MC_RELEASE: release, HOME: home, HAL_C2_MC_HOME: mcHome },
        });

        expect(await errorMessage(host)).toContain("HAL_C2_MC_HOME");
        expect(readRecord(release)).toBeUndefined();
      }
    });

    it("A configured MC release is the MC the desktop app runs", async () => {
      const release = fakeRelease();
      const { host } = await standalone({ release });

      expect(readRecord(release)?.argv).toEqual(["start"]);
      await host.quit();
    });

    it("In a checkout without a release the MC runs from source", () => {
      const hostDir = "/checkout/apps/desktop-qt/host";
      const launch = resolveMcLaunch(
        hostDir,
        {},
        (path) => path === "/checkout/apps/server-ex/mix.exs",
      );

      expect(launch).toEqual({
        command: "mix",
        args: ["hal_c2.server"],
        cwd: "/checkout/apps/server-ex",
      });
    });

    it("An MC run from source runs in the development environment", async () => {
      const launch = {
        command: process.execPath,
        args: ["-e", "process.stdout.write(`MIX_ENV=${process.env.MIX_ENV}`)"],
        cwd: temporaryDirectory(),
      };
      const mc = startMc({ launch, port: 0, home: undefined, env: { MIX_ENV: "prod" } });

      await mc.exited;
      expect(mc.output()).toBe("MIX_ENV=dev");
    });

    it("An MC run from source keeps its access token in the development profile", () => {
      const launch = { command: "mix", args: ["hal_c2.server"], cwd: "/checkout/apps/server-ex" };
      const env = { XDG_DATA_HOME: "/xdg/data" };

      expect(mcDataDir({ launch, home: undefined, env, homeDir: "/home/user" })).toBe(
        "/xdg/data/hal-c2-dev/elixir",
      );
      expect(
        mcDataDir({
          launch: { command: "/release/bin/hal_c2", args: ["start"] },
          home: undefined,
          env,
          homeDir: "/home/user",
        }),
      ).toBe("/xdg/data/hal-c2/elixir");

      // A source MC does not read HAL_C2_HOME; a release, HAL_C2_MC_HOME and the desktop's home do count.
      const ambient = { ...env, HAL_C2_HOME: "/srv/hal-c2" };
      expect(mcDataDir({ launch, home: undefined, env: ambient, homeDir: "/home/user" })).toBe(
        "/xdg/data/hal-c2-dev/elixir",
      );
      expect(
        mcDataDir({
          launch: { command: "/release/bin/hal_c2", args: ["start"] },
          home: undefined,
          env: ambient,
          homeDir: "/home/user",
        }),
      ).toBe("/srv/hal-c2/data/elixir");
      expect(
        mcDataDir({
          launch,
          home: undefined,
          env: { ...ambient, HAL_C2_MC_HOME: "/srv/mc" },
          homeDir: "/home/user",
        }),
      ).toBe("/srv/mc/data");
      expect(mcDataDir({ launch, home: "/tmp/sandbox", env: ambient, homeDir: "/home/user" })).toBe(
        "/tmp/sandbox/data/elixir",
      );
    });

    it("The MC's JavaScript sidecars run on the desktop app's Node", async () => {
      const { release, host } = await standalone();

      expect(readRecord(release)?.nodeCommand).toBe(nodeBin);
      await host.quit();
    });

    it("Without a configured port the MC takes the next free one", async () => {
      // Taken either by this test or by an MC already running on this machine.
      await occupy(3780);
      const { release, host } = await standalone({ env: { HAL_C2_MC_PORT: "" } });

      expect(readRecord(release)?.bootstrap.port).toBeGreaterThan(3780);
      await host.quit();
    });
  });

  describe("Starting the desktop app starts its MC and connects to it", () => {
    it("An MC already running on the desktop's files is used instead of starting another", async () => {
      const mc = await runningMc();
      const data = temporaryDirectory();
      const state = temporaryDirectory();
      // Where the installed MC keeps its files: the hal-c2 profile's elixir level.
      const dirs = {
        data: NodePath.join(data, "hal-c2", "elixir"),
        state: NodePath.join(state, "hal-c2", "elixir"),
      };
      NodeFS.mkdirSync(dirs.data, { recursive: true });
      NodeFS.mkdirSync(dirs.state, { recursive: true });
      writeRuntimeRecord(dirs.state, mc.origin);
      NodeFS.writeFileSync(NodePath.join(dirs.data, "access-token"), "service-mc-token\n");
      const release = fakeRelease();
      const host = startHost({
        env: { HAL_C2_MC_RELEASE: release, XDG_DATA_HOME: data, XDG_STATE_HOME: state },
      });

      expect(await ready(host)).toEqual({ origin: mc.origin, token: "service-mc-token" });
      expect(readRecord(release)).toBeUndefined();
      await host.quit();
    });

    it("A running MC whose access token cannot be read stops the start", async () => {
      const mc = await runningMc();
      const data = temporaryDirectory();
      const state = temporaryDirectory();
      const stateDir = NodePath.join(state, "hal-c2", "elixir");
      NodeFS.mkdirSync(stateDir, { recursive: true });
      writeRuntimeRecord(stateDir, mc.origin);
      const release = fakeRelease();
      const host = startHost({
        env: { HAL_C2_MC_RELEASE: release, XDG_DATA_HOME: data, XDG_STATE_HOME: state },
      });

      expect(await errorMessage(host)).toContain("its access token cannot be read");
      expect(readRecord(release)).toBeUndefined();
    });
  });

  describe("Starting again reuses the environment", () => {
    it("Restarting the desktop app connects to the same environment again", async () => {
      const home = temporaryDirectory();
      const first = await standalone({ home });
      const firstEnvironment = await descriptorOf(first.mc.origin);
      await first.host.quit();

      const second = await standalone({ home });

      expect((await descriptorOf(second.mc.origin)).environmentId).toBe(
        firstEnvironment.environmentId,
      );
      await second.host.quit();
    });
  });

  describe("Attaching to a running MC with its pairing link", () => {
    it("Attaching to an MC with its pairing link", async () => {
      const mc = await runningMc();
      const ownRelease = fakeRelease();
      const host = startHost({
        args: [`--attach=${mc.origin}/?token=pairing-token`],
        env: { HAL_C2_MC_RELEASE: ownRelease },
      });

      expect(await ready(host)).toEqual({ origin: mc.origin, token: "access" });
      expect(readRecord(ownRelease)).toBeUndefined();
      await host.quit();
    });

    it("An attached desktop's own client is given the token of an MC on this machine", async () => {
      const mc = await runningMc();
      const data = temporaryDirectory();
      const state = temporaryDirectory();
      // Where `mise run mc` keeps its files: the hal-c2-dev profile's elixir level.
      const mcDirs = devMcDirs({ data, state });
      writeRuntimeRecord(mcDirs.state, mc.origin);
      NodeFS.writeFileSync(NodePath.join(mcDirs.data, "access-token"), "local-mc-token\n");
      const host = startHost({
        args: [`--attach=${mc.origin}/?token=pairing-token`],
        env: { XDG_DATA_HOME: data, XDG_STATE_HOME: state },
      });

      expect(await ready(host)).toEqual({ origin: mc.origin, token: "local-mc-token" });
      await host.quit();
    });

    it("An attached desktop's own client pairs with an MC it has no files for", async () => {
      const mc = await runningMc();
      const data = temporaryDirectory();
      const state = temporaryDirectory();
      const mcDirs = devMcDirs({ data, state });
      writeRuntimeRecord(mcDirs.state, `http://127.0.0.1:${await freePort()}`);
      NodeFS.writeFileSync(NodePath.join(mcDirs.data, "access-token"), "other-mc-token\n");
      const host = startHost({
        args: [`--attach=${mc.origin}/#token=pairing-token`],
        env: { XDG_DATA_HOME: data, XDG_STATE_HOME: state },
      });

      expect(await ready(host)).toEqual({ origin: mc.origin, token: "access" });
      await host.quit();
    });

    it("Attaching with a pairing link the MC refuses", async () => {
      const mc = await runningMc();
      const host = startHost({ args: [`--attach=${mc.origin}/?token=spent`] });

      expect(await errorMessage(host)).toBe(
        `The pairing link for ${mc.origin} is invalid or expired.`,
      );
      expect(await host.exited).toBe(1);
    });

    it("An address that is not an MC is refused", async () => {
      const server = NodeHttp.createServer((_request, response) => {
        response.writeHead(404).end();
      });
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      cleanups.push(() => server.close());
      const { port } = server.address() as NodeNet.AddressInfo;
      const host = startHost({ args: [`--attach=http://127.0.0.1:${port}/some/page?x=1`] });

      expect(await errorMessage(host)).toBe(
        `http://127.0.0.1:${port} is not a HAL-C2 MC. ` +
          "Start the desktop app with an MC's pairing link to attach to it.",
      );
      expect(await host.exited).toBe(1);
    });

    it("Attaching to an MC that is not running", async () => {
      const port = await freePort();
      const host = startHost({ args: [`--attach=http://127.0.0.1:${port}/?token=abc`] });

      expect(await errorMessage(host)).toContain(`Cannot reach the MC at http://127.0.0.1:${port}`);
      expect(await host.exited).toBe(1);
    });
  });

  describe("Quitting the desktop app stops the MC it started", () => {
    it("Quitting the desktop app stops its MC", async () => {
      const { release, host, mc } = await standalone();

      expect(await host.quit()).toBe(0);
      expect(NodeFS.existsSync(NodePath.join(release, "stopped"))).toBe(true);
      await expect(descriptorOf(mc.origin)).rejects.toThrow();
    });

    it("Quitting an attached desktop app leaves the MC running", async () => {
      const mc = await runningMc();
      const host = startHost({ args: [`--attach=${mc.origin}/?token=pairing-token`] });
      await ready(host);

      expect(await host.quit()).toBe(0);
      expect(NodeFS.existsSync(NodePath.join(mc.release, "stopped"))).toBe(false);
      expect((await descriptorOf(mc.origin)).environmentId).toMatch(/^env-/);
    });
  });

  describe("Start-up failures say what went wrong", () => {
    it("The MC fails to start", async () => {
      const host = startHost({
        env: {
          HAL_C2_MC_RELEASE: fakeRelease(),
          HAL_C2_MC_PORT: String(await freePort()),
          FAKE_MC_FAIL: "3",
        },
      });

      const message = await errorMessage(host);
      expect(message).toContain("The MC failed to start (exit code 3)");
      expect(message).toContain("fake MC: boom");
      expect(await host.exited).toBe(1);
    });

    it("The MC's port the desktop app was told to use is taken", async () => {
      const release = fakeRelease();
      const taken = await occupy();
      const host = startHost({
        env: { HAL_C2_MC_RELEASE: release, HAL_C2_MC_PORT: String(taken) },
      });

      const message = await errorMessage(host);
      expect(message).toContain(`Port ${taken}`);
      expect(message).toContain("in use");
      expect(message).toContain("HAL_C2_MC_PORT");
      expect(await host.exited).toBe(1);
      expect(readRecord(release)).toBeUndefined();
    });
  });
});

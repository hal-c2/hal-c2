// The MC of this checkout on a scratch home, for scenarios about what only the MC can
// prove, such as its output window. It runs from the build the MC's own tests use, with
// nothing reaching a real model or registry; `HAL_C2_MC_HOME` keeps it off any real state.
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

const SERVER_DIR = NodePath.resolve(import.meta.dir, "../../../server-ex");

// The test config leaves the MC's services to each test; this is the one that wants them all.
const BOOT = [
  "Application.put_env(:hal_c2, :start_mc, true)",
  "{:ok, _} = Application.ensure_all_started(:hal_c2)",
  "Mix.Tasks.HalC2.Server.announce()",
  "Process.sleep(:infinity)",
].join("; ");

export interface RealMc {
  readonly origin: string;
  readonly accessToken: string;
  /** Its scratch home, removed by `stop`. */
  readonly home: string;
  /** Stops the process it started, by pid, and removes the home. */
  readonly stop: () => Promise<void>;
}

function freePort(): number {
  const probe = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: { data() {} },
  });
  const { port } = probe;
  probe.stop(true);
  return port;
}

/** What the MC finds in its environment: this one's, minus what points at real state. */
function mcEnv(home: string, port: number) {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value === undefined || key.startsWith("HAL_C2_") || key.startsWith("XDG_")) continue;
    env[key] = value;
  }
  return {
    ...env,
    MIX_ENV: "test",
    SHELL: "/bin/sh",
    HAL_C2_MC_HOME: home,
    HAL_C2_MC_PORT: String(port),
  };
}

export async function startRealMc(): Promise<RealMc> {
  const home = NodeFS.mkdtempSync(NodePath.join(process.env.TMPDIR ?? NodeOS.tmpdir(), "tui-mc-"));
  const port = freePort();
  const mix = Bun.which("mix") ? ["mix"] : ["mise", "exec", "--", "mix"];
  const proc = Bun.spawn([...mix, "run", "--no-start", "-e", BOOT], {
    cwd: SERVER_DIR,
    env: mcEnv(home, port),
    stdin: "ignore",
    stdout: "pipe",
    stderr: NodeFS.openSync(NodePath.join(home, "mc.stderr"), "w"),
  });

  const stop = async () => {
    proc.kill("SIGTERM");
    await proc.exited;
    NodeFS.rmSync(home, { recursive: true, force: true });
  };

  // Its announcement says the MC is listening; the pipe is read to the end after that.
  const announced = new Promise<string | null>((resolve) => {
    void (async () => {
      let text = "";
      for await (const part of proc.stdout.pipeThrough(new TextDecoderStream())) {
        text += part;
        const token = /\/ws\?(?:[^\s&]*&)*token=([^\s&]+)/.exec(text)?.[1];
        if (token) resolve(token);
      }
      resolve(null);
    })();
  });
  const accessToken = await announced;
  if (accessToken === null) {
    const stderr = NodeFS.readFileSync(NodePath.join(home, "mc.stderr"), "utf8");
    await stop();
    throw new Error(`The MC did not start:\n${stderr}`);
  }
  return { origin: `http://127.0.0.1:${port}`, accessToken, home, stop };
}

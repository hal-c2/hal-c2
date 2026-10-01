// @effect-diagnostics nodeBuiltinImport:off - the Bun entry reads the MC's files before any Effect runtime exists.
/**
 * How the terminal client finds a HAL-C2 MC without a launcher.
 *
 * Local: the MC writes `<state>/server-runtime.json` while it serves
 * (`apps/server-ex/lib/hal_c2/runtime_record.ex`) and keeps its access token in
 * `<data>/access-token`. Anyone who can read that file already owns the MC, so
 * the client uses the token as its bearer.
 *
 * Remote: `--url <pairing link>` exchanges the link's one-time token for a
 * bearer session labelled "HAL-C2 TUI" and saves it under HAL-C2's data dir,
 * keyed by the environment's origin. An MC does not let a session revoke
 * itself and a link works once, so the session is kept for later launches
 * (`--url <origin>`) until the environment revokes it.
 *
 * Every failure is a {@link LaunchError} whose message is shown as is.
 */
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import {
  bootstrapRemoteBearerSession,
  fetchRemoteSessionState,
} from "@hal-c2/client-runtime/authorization";
import { orchestrationProtocolCompatibilityError } from "@hal-c2/client-runtime/connection";
import { fetchRemoteEnvironmentDescriptor } from "@hal-c2/client-runtime/environment";
import { remoteHttpClientLayer } from "@hal-c2/client-runtime/rpc";
import { resolveRemotePairingTarget } from "@hal-c2/shared/remote";
import {
  absoluteEnvPath,
  HAL_C2_DEV_APP_DIR,
  isLegacyHome,
  resolveHalC2Dirs,
  type HalC2DirsEnvironment,
} from "@hal-c2/shared/xdgDirs";
import * as Effect from "effect/Effect";
import type { HttpClient } from "effect/unstable/http";

/** The label a paired session carries in the environment's client list. */
export const TUI_CLIENT_LABEL = "HAL-C2 TUI";
const MC_DIR = "elixir";
const START_HINT = "Start one with `mise run mc` first.";

export class LaunchError extends Error {}

/** An MC the client can connect to: where it is and who the client is there. */
export interface McTarget {
  /** `http(s)://host:port`, no trailing slash. */
  readonly origin: string;
  readonly bearerToken: string;
  readonly environmentId: string;
  readonly label: string;
  readonly orchestrationProtocolVersion: number | undefined;
}

export interface LaunchArgs {
  readonly url?: string;
  readonly baseDir?: string;
  /** The development profile, `hal-c2-dev`: where a main checkout's `mise run mc` lives. */
  readonly dev?: boolean;
}

/** `[--url <pairing link or origin>] [--base-dir <root>] [--dev]`, `--flag=value` too. */
export function parseLaunchArgs(argv: ReadonlyArray<string>): LaunchArgs {
  const args: { url?: string; baseDir?: string; dev?: boolean } = {};
  for (let index = 0; index < argv.length; index++) {
    const arg = argv[index]!;
    if (arg === "--dev") {
      args.dev = true;
      continue;
    }
    const [flag, inline] = arg.startsWith("--") ? splitOnce(arg, "=") : [arg, undefined];
    if (flag !== "--url" && flag !== "--base-dir") {
      throw new LaunchError(
        `Unknown argument ${arg}. Usage: hal-c2-tui [--url <pairing link>] [--base-dir <dir>] [--dev]`,
      );
    }
    const value = inline ?? argv[++index];
    if (value === undefined || value.trim() === "") {
      throw new LaunchError(`${flag} needs a value.`);
    }
    if (flag === "--url") args.url = value.trim();
    else args.baseDir = NodePath.resolve(value.trim());
  }
  return args;
}

function splitOnce(value: string, separator: string): [string, string | undefined] {
  const at = value.indexOf(separator);
  return at < 0 ? [value, undefined] : [value.slice(0, at), value.slice(at + 1)];
}

export interface DirsInput {
  readonly baseDir?: string | undefined;
  readonly dev?: boolean | undefined;
  readonly env: HalC2DirsEnvironment & Readonly<Record<string, string | undefined>>;
  readonly homeDir: string;
  readonly platform: NodeJS.Platform;
}

/**
 * The MC's state and data dirs, as `HalC2.Paths` lays them out: a root
 * (`--base-dir`, `HAL_C2_HOME`) or the XDG dirs (the `hal-c2-dev` profile with
 * `--dev`) with an `elixir` level, or `HAL_C2_MC_HOME` holding `state` and
 * `data` directly.
 */
export function resolveMcDirs(input: DirsInput): { state: string; data: string } {
  const path = input.platform === "win32" ? NodePath.win32 : NodePath.posix;
  const mcHome = absoluteEnvPath(input.env.HAL_C2_MC_HOME, input.platform);
  if (input.baseDir === undefined && mcHome !== undefined && !isLegacyHome(mcHome, input)) {
    return { state: path.join(mcHome, "state"), data: path.join(mcHome, "data") };
  }
  const dirs = halC2Dirs(input);
  return { state: path.join(dirs.state, MC_DIR), data: path.join(dirs.data, MC_DIR) };
}

/** Where paired sessions are saved: HAL-C2's (not the MC's) data dir. */
export function credentialsPath(input: DirsInput): string {
  return NodePath.join(halC2Dirs(input).data, "tui", "credentials.json");
}

const halC2Dirs = (input: DirsInput) =>
  resolveHalC2Dirs({
    ...input,
    root: input.baseDir,
    profile: input.dev ? HAL_C2_DEV_APP_DIR : undefined,
  });

/** `kill(pid, 0)`: EPERM still means the process exists. */
export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

interface Io {
  readonly fetch?: typeof globalThis.fetch;
}

/** Runs a client-runtime HTTP call; a failure rejects with the call's own error. */
const runHttp = <A, E>(effect: Effect.Effect<A, E, HttpClient.HttpClient>, io: Io): Promise<A> =>
  Effect.runPromise(
    effect.pipe(Effect.provide(remoteHttpClientLayer(io.fetch ?? globalThis.fetch))),
  );

function reason(error: unknown): string {
  const message =
    typeof error === "object" && error !== null && "message" in error
      ? String((error as { message: unknown }).message)
      : String(error);
  return message.replace(/\.$/, "");
}

/** A failure to talk to the MC at all, as opposed to the MC saying no. */
function isTransportError(error: unknown): boolean {
  const tag = (error as { _tag?: unknown } | null)?._tag;
  return tag === "RemoteEnvironmentAuthFetchError" || tag === "RemoteEnvironmentAuthTimeoutError";
}

async function describe(origin: string, io: Io) {
  try {
    const descriptor = await runHttp(fetchRemoteEnvironmentDescriptor({ httpBaseUrl: origin }), io);
    const blocked = orchestrationProtocolCompatibilityError(descriptor);
    if (blocked) throw new LaunchError(blocked.detail);
    return descriptor;
  } catch (error) {
    if (error instanceof LaunchError) throw error;
    throw new LaunchError(`The HAL-C2 MC at ${origin} could not be reached: ${reason(error)}.`);
  }
}

async function target(origin: string, bearerToken: string, io: Io): Promise<McTarget> {
  const descriptor = await describe(origin, io);
  return {
    origin,
    bearerToken,
    environmentId: descriptor.environmentId,
    label: descriptor.label,
    orchestrationProtocolVersion: descriptor.orchestrationProtocolVersion,
  };
}

interface RuntimeRecord {
  readonly pid: number;
  readonly origin: string;
}

function readRuntimeRecord(path: string): RuntimeRecord | null {
  let text: string;
  try {
    text = NodeFS.readFileSync(path, "utf8");
  } catch {
    return null;
  }
  try {
    const record = JSON.parse(text) as Partial<RuntimeRecord>;
    if (typeof record.pid === "number" && typeof record.origin === "string") {
      return { pid: record.pid, origin: record.origin.replace(/\/+$/, "") };
    }
  } catch {
    // A torn or foreign file reads as no record.
  }
  return null;
}

/** The MC running on this machine, signed in with its access token. */
export async function findLocalMc(
  input: {
    readonly dirs: { state: string; data: string };
    readonly isAlive?: (pid: number) => boolean;
  } & Io,
): Promise<McTarget> {
  const recordPath = NodePath.join(input.dirs.state, "server-runtime.json");
  const record = readRuntimeRecord(recordPath);
  if (!record) {
    throw new LaunchError(
      `No running HAL-C2 MC was found. ${START_HINT}\n(looked for ${recordPath})`,
    );
  }
  if (!(input.isAlive ?? isProcessAlive)(record.pid)) {
    throw new LaunchError(
      `The recorded HAL-C2 MC (pid ${record.pid}) is no longer running. ${START_HINT}`,
    );
  }
  const mc = await target(record.origin, "", input);
  const tokenPath = NodePath.join(input.dirs.data, "access-token");
  let token = "";
  try {
    token = NodeFS.readFileSync(tokenPath, "utf8").trim();
  } catch {
    // Reported below.
  }
  if (!token) {
    throw new LaunchError(`The HAL-C2 MC at ${record.origin} has no access token at ${tokenPath}.`);
  }
  return { ...mc, bearerToken: token };
}

interface SavedSessions {
  readonly version: 1;
  readonly sessions: Record<string, { readonly bearerToken: string; readonly pairedAt: string }>;
}

function readSaved(path: string): SavedSessions {
  try {
    const saved = JSON.parse(NodeFS.readFileSync(path, "utf8")) as SavedSessions;
    if (saved.version === 1 && typeof saved.sessions === "object" && saved.sessions !== null) {
      return saved;
    }
  } catch {
    // Missing or unreadable: nothing saved.
  }
  return { version: 1, sessions: {} };
}

function writeSaved(path: string, saved: SavedSessions): void {
  NodeFS.mkdirSync(NodePath.dirname(path), { recursive: true, mode: 0o700 });
  const temp = `${path}.${process.pid}.tmp`;
  NodeFS.writeFileSync(temp, `${JSON.stringify(saved, null, 2)}\n`, { mode: 0o600 });
  NodeFS.renameSync(temp, path);
}

function withSession(
  saved: SavedSessions,
  origin: string,
  bearerToken: string | null,
): SavedSessions {
  const sessions = { ...saved.sessions };
  if (bearerToken === null) delete sessions[origin];
  else sessions[origin] = { bearerToken, pairedAt: new Date().toISOString() };
  return { version: 1, sessions };
}

/** Pair with (or come back to) a remote environment from a pairing link or its origin. */
export async function connectRemoteMc(
  input: { readonly url: string; readonly credentialsPath: string } & Io,
): Promise<McTarget> {
  let origin: string;
  let credential: string | null = null;
  try {
    const pairing = resolveRemotePairingTarget({ pairingUrl: input.url });
    origin = new URL(pairing.httpBaseUrl).origin;
    credential = pairing.credential;
  } catch (error) {
    const tag = (error as { _tag?: unknown })._tag;
    if (tag !== "RemotePairingTokenMissingError") {
      throw new LaunchError(`${input.url} is not a HAL-C2 pairing link.`);
    }
    origin = new URL(input.url).origin;
  }

  const mc = await target(origin, "", input);
  let saved = readSaved(input.credentialsPath);
  const savedToken = saved.sessions[origin]?.bearerToken;
  if (savedToken) {
    const state = await runHttp(
      fetchRemoteSessionState({ httpBaseUrl: origin, bearerToken: savedToken }),
      input,
    ).catch((error: unknown) => {
      if (isTransportError(error)) {
        throw new LaunchError(`The HAL-C2 MC at ${origin} could not be reached: ${reason(error)}.`);
      }
      return { authenticated: false };
    });
    if (state.authenticated) return { ...mc, bearerToken: savedToken };
    saved = withSession(saved, origin, null);
    writeSaved(input.credentialsPath, saved);
    if (credential === null) {
      throw new LaunchError(
        `${origin} revoked this terminal client's access. Start it again with a new pairing link: --url <pairing link>.`,
      );
    }
  }
  if (credential === null) {
    throw new LaunchError(
      `This terminal client is not paired with ${origin}. Start it with a pairing link from that environment: --url <pairing link>.`,
    );
  }

  const issued = await runHttp(
    bootstrapRemoteBearerSession({
      httpBaseUrl: origin,
      credential,
      clientMetadata: { label: TUI_CLIENT_LABEL },
    }),
    input,
  ).catch((error: unknown) => {
    if (isTransportError(error)) {
      throw new LaunchError(`The HAL-C2 MC at ${origin} could not be reached: ${reason(error)}.`);
    }
    throw new LaunchError(
      `The pairing link for ${origin} was already used or has expired. Ask that environment for a new one.`,
    );
  });
  writeSaved(input.credentialsPath, withSession(saved, origin, issued.access_token));
  return { ...mc, bearerToken: issued.access_token };
}

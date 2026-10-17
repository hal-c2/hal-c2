import * as NodeChildProcess from "node:child_process";
import * as NodeCrypto from "node:crypto";
import * as NodeFSP from "node:fs/promises";

/**
 * Which MCs run on the machine the user sits at: only there may an editor or a
 * file manager start for them. As the desktop decides it
 * (apps/desktop-qt/src/native/ThisMachine.cpp), from the id the MC serves as
 * `platform.machineId` (apps/server-ex/lib/hal_c2/environment/machine.ex).
 */

const run = (command: string, args: ReadonlyArray<string>) =>
  new Promise<string | null>((resolve) =>
    NodeChildProcess.execFile(command, args, (error, stdout) => resolve(error ? null : stdout)),
  );

/** The first 32 bytes of the first D-Bus machine id file there is, as Qt reads it. */
async function dbusId(paths: ReadonlyArray<string>): Promise<Buffer | null> {
  for (const path of paths) {
    try {
      const file = await NodeFSP.open(path, "r");
      try {
        const { buffer, bytesRead } = await file.read(Buffer.alloc(32), 0, 32, 0);
        return buffer.subarray(0, bytesRead);
      } finally {
        await file.close();
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") return null;
    }
  }
  return null;
}

/** The bytes QSysInfo::machineUniqueId() returns on this machine, or null. */
async function rawId(): Promise<Buffer | null> {
  // oxlint-disable-next-line hal-c2/no-global-process-runtime -- @hal-c2/shared/hostProcess imports node:sea, which the Bun-run TUI lacks.
  switch (process.platform) {
    case "darwin": {
      const out = await run("ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"]);
      const id = out?.match(/"IOPlatformUUID"\s*=\s*"([^"]+)"/)?.[1];
      return id ? Buffer.from(id, "latin1") : null;
    }
    case "win32": {
      const out = await run("reg", [
        "query",
        "HKLM\\SOFTWARE\\Microsoft\\Cryptography",
        "/v",
        "MachineGuid",
        "/reg:64",
      ]);
      const id = out?.match(/MachineGuid\s+REG_SZ\s+(\S+)/)?.[1];
      return id ? Buffer.from(id, "latin1") : null;
    }
    default:
      return dbusId(["/var/lib/dbus/machine-id", "/usr/local/var/lib/dbus/machine-id"]);
  }
}

/** The lowercase hex SHA-256 of a machine id's bytes, null for none. */
export const hashMachineId = (raw: Uint8Array | null): string | null =>
  raw && raw.length > 0 ? NodeCrypto.createHash("sha256").update(raw).digest("hex") : null;

let cached: Promise<string | null> | undefined;
/** This machine's id as an MC on it serves it, read once. */
export const thisMachineId = (): Promise<string | null> =>
  (cached ??= rawId().then(hashMachineId, () => null));

/**
 * Whether `host` (a URL's hostname) is this machine's loopback: localhost,
 * 127.0.0.0/8, ::1, and 127.0.0.0/8 mapped into IPv6, which a URL writes in hex
 * (`[::ffff:7f00:1]`).
 */
export function loopbackHost(host: string): boolean {
  const bare = host.toLowerCase().replace(/^\[(.*)\]$/, "$1");
  if (bare === "localhost" || bare === "::1") return true;
  if (/^::ffff:7f[0-9a-f]{2}:[0-9a-f]{1,4}$/.test(bare)) return true;
  const v4 = bare.replace(/^::ffff:/, "");
  return /^127(\.\d{1,3}){3}$/.test(v4);
}

/**
 * Whether an MC runs here: its id is ours. Without an id on both sides, it is
 * the MC the client connected to (`own`), reached on loopback at `origin`. A
 * loopback origin alone is not enough when the ids are known: an SSH port
 * forward is loopback too.
 */
export function hostedHere(input: {
  readonly ours: string | null;
  readonly theirs: string | null | undefined;
  readonly own: boolean;
  readonly origin: string;
}): boolean {
  if (input.ours && input.theirs) return input.ours === input.theirs;
  if (!input.own) return false;
  try {
    return loopbackHost(new URL(input.origin).hostname);
  } catch {
    return false;
  }
}

/**
 * Where a file is on this machine: its path, or what the user is told when it has none.
 * `environmentId` names the MC on this machine that starts an app for it when that is
 * a cluster member rather than the client's own MC.
 */
export type LocalPath =
  | { readonly path: string; readonly environmentId?: string }
  | { readonly problem: string };

/** What the user is told about a file on a machine that keeps no folder here. */
export const FILES_ELSEWHERE = "The files are on another machine and can't be opened here yet.";

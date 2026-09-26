import {
  resolveDesktopAppControlAddress,
  type DesktopAppControlAddress,
} from "./desktopAppControl.ts";

/** Unix socket paths longer than this do not fit `sun_path` on macOS (104 bytes incl. NUL). */
const MAX_UNIX_SOCKET_PATH_BYTES = 103;

/**
 * Returns the desktop app's control socket in the HAL-C2 runtime directory.
 *
 * The socket is named after a hash of the state directory, so each HAL-C2
 * install and profile gets its own. Windows keeps its named pipe. A runtime
 * directory too long for a Unix socket path falls back to the per-user temp
 * directory so a deep custom root still gets a working socket.
 */
export function resolveDesktopAppControlSocket(input: {
  readonly dirs: { readonly state: string; readonly runtime: string };
  readonly platform: NodeJS.Platform;
  readonly tempDir: string;
  readonly userId: number | undefined;
  readonly joinPath: (...segments: readonly string[]) => string;
}): DesktopAppControlAddress {
  const fallback = resolveDesktopAppControlAddress({
    stateDir: input.dirs.state,
    platform: input.platform,
    tempDir: input.tempDir,
    userId: input.userId,
    joinPath: input.joinPath,
  });
  if (input.platform === "win32" || fallback.directory === null) {
    return fallback;
  }
  const socketName = fallback.address.slice(fallback.directory.length + 1);
  const address = input.joinPath(input.dirs.runtime, socketName);
  if (new TextEncoder().encode(address).byteLength > MAX_UNIX_SOCKET_PATH_BYTES) {
    return fallback;
  }
  return { address, directory: input.dirs.runtime };
}

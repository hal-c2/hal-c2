// @effect-diagnostics nodeBuiltinImport:off - process launcher, deliberately Effect-free.
/**
 * Serves the built web app (apps/web/dist) from a loopback port, the way the
 * hosted app is served: static files, `index.html` for every route, no API and
 * no proxy. The node serves no app; the page reaches it cross-origin.
 *
 * Loopback HTTP rather than a custom scheme: `http://127.0.0.1` is a secure
 * context (WebCrypto, DPoP keys) that can still reach `http://` LAN and tailnet
 * nodes, and Qt WebEngine keeps IndexedDB and localStorage per origin without a
 * C++ scheme handler. The port is derived from the HAL-C2 home so the origin,
 * and with it the saved environments, drafts and settings, survive restarts.
 */
import * as NodeFS from "node:fs";
import * as NodeHttp from "node:http";
import * as NodePath from "node:path";

import { HostError } from "./hostError.ts";

const CONTENT_TYPES: Readonly<Record<string, string>> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".webmanifest": "application/manifest+json",
  ".map": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".avif": "image/avif",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".wasm": "application/wasm",
  ".mp3": "audio/mpeg",
  ".wav": "audio/wav",
  ".ogg": "audio/ogg",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
  ".txt": "text/plain; charset=utf-8",
};

/** First port of the range the web origin is derived into. */
const WEB_PORT_BASE = 20_000;
const WEB_PORT_SPAN = 12_000;

/**
 * The built web app: `HAL_C2_WEB_DIST`, the copy staged next to the host in a
 * package, or `apps/web/dist` in a checkout. Throws when none holds an
 * `index.html`.
 */
export function resolveWebBundle(
  hostDir: string,
  env: NodeJS.ProcessEnv,
  exists: (path: string) => boolean = NodeFS.existsSync,
): string {
  const configured = env.HAL_C2_WEB_DIST?.trim();
  const candidates = configured
    ? [NodePath.resolve(configured)]
    : [NodePath.resolve(hostDir, "../web"), NodePath.resolve(hostDir, "../../web/dist")];
  const found = candidates.find((dir) => exists(NodePath.join(dir, "index.html")));
  if (found !== undefined) {
    return found;
  }
  throw new HostError(
    `The app bundle is missing: no index.html in ${candidates.join(" or ")}. ` +
      "Build it with `vp run --filter @hal-c2/web build`, or point HAL_C2_WEB_DIST at a built apps/web/dist.",
  );
}

/** FNV-1a, so one HAL-C2 home always lands on the same port. */
function fnv1a(text: string): number {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash;
}

/**
 * The app's port: `HAL_C2_WEB_PORT`, else one derived from the HAL-C2 home
 * (empty for the default XDG home), stable across restarts.
 */
export function webPort(env: NodeJS.ProcessEnv, home: string | undefined): number {
  const configured = env.HAL_C2_WEB_PORT?.trim();
  if (configured) {
    const port = Number(configured);
    if (!Number.isInteger(port) || port < 1 || port > 65_535) {
      throw new HostError(`HAL_C2_WEB_PORT is not a port: ${configured}`);
    }
    return port;
  }
  return WEB_PORT_BASE + (fnv1a(home ?? "") % WEB_PORT_SPAN);
}

function contentType(file: string): string {
  return CONTENT_TYPES[NodePath.extname(file).toLowerCase()] ?? "application/octet-stream";
}

/** The file under `root` a request path names, or undefined when it escapes `root`. */
function fileFor(root: string, pathname: string): string | undefined {
  let decoded: string;
  try {
    decoded = decodeURIComponent(pathname);
  } catch {
    return undefined;
  }
  const file = NodePath.resolve(root, `.${NodePath.posix.normalize(`/${decoded}`)}`);
  return file === root || file.startsWith(`${root}${NodePath.sep}`) ? file : undefined;
}

function isFile(file: string): boolean {
  try {
    return NodeFS.statSync(file).isFile();
  } catch {
    return false;
  }
}

export interface WebServer {
  readonly origin: string;
  close(): Promise<void>;
}

/** Serves `root` on `127.0.0.1:<port>`; unknown paths get `index.html` (SPA routes). */
export function serveWebBundle(input: {
  readonly root: string;
  readonly port: number;
}): Promise<WebServer> {
  const root = NodePath.resolve(input.root);
  const index = NodePath.join(root, "index.html");
  const server = NodeHttp.createServer((request, response) => {
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405, { allow: "GET, HEAD" }).end();
      return;
    }
    const pathname = new URL(request.url ?? "/", "http://127.0.0.1").pathname;
    const requested = fileFor(root, pathname);
    if (requested === undefined) {
      response.writeHead(400).end();
      return;
    }
    const asset = isFile(requested);
    // Missing hashed assets are real 404s; any other path is an app route.
    if (!asset && pathname.startsWith("/assets/")) {
      response.writeHead(404).end();
      return;
    }
    const file = asset ? requested : index;
    response.writeHead(200, {
      "content-type": contentType(file),
      "cache-control": pathname.startsWith("/assets/")
        ? "public, max-age=31536000, immutable"
        : "no-cache",
    });
    if (request.method === "HEAD") {
      response.end();
      return;
    }
    NodeFS.createReadStream(file)
      .on("error", () => response.destroy())
      .pipe(response);
  });

  return new Promise((resolve, reject) => {
    server.once("error", (error: NodeJS.ErrnoException) => {
      reject(
        error.code === "EADDRINUSE"
          ? new HostError(
              `Port ${input.port} for the app is in use by another program. ` +
                "Set HAL_C2_WEB_PORT to a free port.",
            )
          : error,
      );
    });
    server.listen(input.port, "127.0.0.1", () => {
      resolve({
        origin: `http://127.0.0.1:${input.port}`,
        close: () =>
          new Promise<void>((done) => {
            server.closeAllConnections();
            server.close(() => done());
          }),
      });
    });
  });
}

import * as NodeFS from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createCliRenderer } from "@opentui/core";
import { installKittyClipboardExtension } from "@t3tools/opentui-image";
import { runShell } from "opentui-qml";

import { buildTuiRuntime, makeTuiClient, type TuiOptions } from "./connection.ts";
import { detectKittyGraphicsTerminal } from "./terminalGraphics.ts";
import { createHost } from "./host/host.ts";
import { enginePluginPort } from "./host/plugins.ts";
import { readUserConfig } from "./host/userConfig.ts";
import {
  ensureColorCapabilityEnv,
  prepareTerminalViewport,
  TUI_RENDERER_CONFIG,
} from "./terminalStartup.ts";

// This is the Bun entry point spawned by the Node `t3 tui` command. It receives
// the server origin + a bearer token via env, and mints fresh websocket URLs by
// asking the parent (which holds EnvironmentAuth) over the Node IPC channel —
// the parent stays alive for the whole session and answers each request.

interface SocketUrlReply {
  readonly type: "socketUrl";
  readonly id: number;
  readonly url: string | null;
  readonly error?: string;
}

let nextRequestId = 1;
const pending = new Map<number, { resolve: (url: string) => void; reject: (e: Error) => void }>();

process.on("message", (raw: unknown) => {
  if (typeof raw !== "object" || raw === null) return;
  const message = raw as Partial<SocketUrlReply>;
  if (message.type !== "socketUrl" || typeof message.id !== "number") return;
  const entry = pending.get(message.id);
  if (!entry) return;
  pending.delete(message.id);
  if (typeof message.url === "string") entry.resolve(message.url);
  else entry.reject(new Error(message.error ?? "failed to mint socket url"));
});

// If the parent goes away mid-request, settle outstanding mints instead of
// leaving them (and the reconnect loop that awaits them) hung forever.
process.on("disconnect", () => {
  for (const entry of pending.values()) {
    entry.reject(new Error("t3 parent IPC channel closed"));
  }
  pending.clear();
});

const mintSocketUrl = (): Promise<string> =>
  new Promise<string>((resolve, reject) => {
    const send = process.send as ((message: unknown) => boolean) | undefined;
    if (typeof send !== "function") {
      reject(new Error("no IPC channel to the t3 parent process"));
      return;
    }
    const id = nextRequestId++;
    const timer = setTimeout(() => {
      if (pending.delete(id)) reject(new Error("timed out minting a websocket url"));
    }, 10_000);
    timer.unref?.();
    pending.set(id, {
      resolve: (url) => {
        clearTimeout(timer);
        resolve(url);
      },
      reject: (error) => {
        clearTimeout(timer);
        reject(error);
      },
    });
    try {
      send.call(process, { type: "mintSocketUrl", id });
    } catch (error) {
      if (pending.delete(id)) {
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    }
  });

/**
 * The `T3.Tui` bricks ship next to the bundle (`dist/qml`, copied by the build)
 * and live at `apps/tui/qml` when running from source.
 */
function resolveQmlDir(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  const bundled = join(here, "qml");
  return NodeFS.existsSync(join(bundled, "T3/Tui/qmldir")) ? bundled : join(here, "../qml");
}

/** Where a user's `shell.qml` (and extra `qml/` modules) override the default shell. */
function resolveShellConfigDir(): string {
  return (
    process.env.T3_TUI_SHELL_DIR ??
    join(process.env.T3CODE_HOME ?? join(homedir(), ".t3"), "shell", "tui")
  );
}

async function main(): Promise<void> {
  const origin = process.env.T3_TUI_ORIGIN;
  const bearerToken = process.env.T3_TUI_BEARER;
  const logPath = process.env.T3_TUI_LOG ?? "/tmp/t3-tui.log";
  if (!origin || !bearerToken) {
    process.stderr.write("t3 tui: missing T3_TUI_ORIGIN / T3_TUI_BEARER\n");
    process.exitCode = 1;
    return;
  }

  const appendLog = (line: string) => {
    try {
      NodeFS.appendFileSync(logPath, `${line}\n`);
    } catch {
      // Diagnostics only — never let logging break the UI.
    }
  };

  // Read the user's keymap and plugin locations before taking over the terminal,
  // so a broken keymap.json stops here with a readable error.
  const configDir = resolveShellConfigDir();
  const configWarnings: string[] = [];
  const userConfig = readUserConfig({
    configDir,
    pluginPaths: process.env.T3_TUI_PLUGINS,
    warn: (message) => configWarnings.push(message),
  });

  const options: TuiOptions = { origin, bearerToken, mintSocketUrl, logPath };
  const runtime = buildTuiRuntime(options);
  const client = makeTuiClient(runtime, origin);

  // A tmux pane can still be showing scrollback when this child starts. Return it
  // to the live screen before entering OpenTUI's alternate screen so the complete
  // first frame is visible without requiring the user to scroll to the bottom.
  prepareTerminalViewport();
  ensureColorCapabilityEnv();

  // Render on a transparent background so the user's terminal theme (and its own
  // background colour) shows through instead of OpenTUI's opaque default. Mouse
  // motion stays disabled so terminal drag-selection works, while clicks and wheel
  // reporting remain enabled explicitly in the shared renderer configuration.
  const tmuxPassthrough = detectKittyGraphicsTerminal();
  const renderer = await createCliRenderer(TUI_RENDERER_CONFIG);

  // Colour bugs are environment-dependent (SSH drops COLORTERM, multiplexers
  // rewrite TERM) and invisible in the output itself, so record what the
  // renderer actually detected: once right after startup and once after the
  // capability handshake has settled.
  const logColorCapabilities = (stage: string) =>
    appendLog(
      `[color-caps ${stage}] TERM=${process.env.TERM ?? ""} COLORTERM=${
        process.env.COLORTERM ?? ""
      } caps=${JSON.stringify(renderer.capabilities)}`,
    );
  logColorCapabilities("startup");
  setTimeout(() => logColorCapabilities("settled"), 2000).unref?.();
  installKittyClipboardExtension(renderer, {
    tmuxPassthrough,
  });

  let resolveDone: () => void = () => {};
  const done = new Promise<void>((resolve) => {
    resolveDone = resolve;
  });
  let exiting = false;
  const handleExit = () => {
    if (exiting) return;
    exiting = true;
    try {
      if (!renderer.isDestroyed) renderer.destroy();
    } catch {
      // best effort — destroy restores the terminal
    }
    resolveDone();
  };

  const host = createHost({
    client,
    size: { columns: renderer.width, rows: renderer.height },
    onQuit: handleExit,
    log: appendLog,
  });
  for (const message of configWarnings) host.reportWarning(message);

  try {
    // Raw mode usually delivers Ctrl+C as a keystroke (the shell dispatches
    // `app.quit`), but some terminals/multiplexers send a real signal — handle
    // both so one press quits. `Qt.quit()` from a user shell destroys the renderer.
    process.once("SIGINT", handleExit);
    process.once("SIGTERM", handleExit);
    renderer.once("destroy", handleExit);
    renderer.on("resize", (columns: number, rows: number) => host.resize({ columns, rows }));

    const qmlDir = resolveQmlDir();
    const app = await runShell({
      appId: "t3",
      renderer,
      defaultShell: join(qmlDir, "T3/Tui/DefaultShell.qml"),
      modules: { "T3.Tui": join(qmlDir, "T3/Tui") },
      importPaths: [qmlDir],
      configDir,
      plugins: [...userConfig.plugins],
      pluginDirs: [...userConfig.pluginDirs],
      ...(userConfig.keymap ? { keymap: userConfig.keymap } : {}),
      singletons: { Shell: host.Shell, Theme: host.Theme },
      watch: process.env.T3_TUI_DEV === "1",
      onWarning: host.reportWarning,
      onError: host.reportError,
    });
    host.attachPlugins(enginePluginPort(app.engine));

    await done;
  } catch (error) {
    // Restore the terminal before the error propagates — otherwise it's left in
    // raw/alt-screen mode with a garbled message.
    handleExit();
    throw error;
  } finally {
    host.destroy();
  }
  // The renderer is already torn down (handleExit). Dispose the RPC runtime, then
  // force-exit: the live WebSocket and the IPC channel to the parent would
  // otherwise keep Bun's event loop alive, so a single Ctrl+C wouldn't fully quit.
  await Promise.race([
    client.dispose().catch(() => {}),
    new Promise((resolve) => setTimeout(resolve, 300)),
  ]);
  process.exit(0);
}

main().catch((error) => {
  process.stderr.write(`t3 tui crashed: ${String(error)}\n`);
  process.exit(1);
});

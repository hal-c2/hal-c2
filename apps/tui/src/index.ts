import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import { createCliRenderer } from "@opentui/core";
import { installKittyClipboardExtension } from "@t3tools/opentui-image";
import { runShell } from "opentui-qml";

import { buildTuiRuntime, makeTuiClient, type TuiOptions } from "./connection.ts";
import { detectInlineImageTransport } from "./terminalGraphics.ts";
import { createHost } from "./host/host.ts";
import { enginePluginPort } from "./host/plugins.ts";
import { readUserConfig } from "./host/userConfig.ts";
import { makeSocketTicketMinter } from "./socketTicket.ts";
import {
  ensureColorCapabilityEnv,
  prepareTerminalViewport,
  scheduleColorCapabilityLog,
  TUI_RENDERER_CONFIG,
} from "./terminalStartup.ts";

// This is the Bun entry point spawned by the Node `t3 tui` command. It receives
// the server origin + a bearer token via env, and mints fresh websocket URLs by
// asking the parent (which holds EnvironmentAuth) over the Node IPC channel —
// the parent stays alive for the whole session and answers each request.

const processSend = process.send as ((message: unknown) => boolean) | undefined;
const socketTickets = makeSocketTicketMinter({
  send:
    typeof processSend === "function" ? (message) => processSend.call(process, message) : undefined,
});
process.on("message", socketTickets.receive);
process.on("disconnect", socketTickets.disconnect);
const mintSocketUrl = socketTickets.mint;

/**
 * The `T3.Tui` bricks ship next to the bundle (`dist/qml`, copied by the build)
 * and live at `apps/tui/qml` when running from source.
 */
function resolveQmlDir(): string {
  const here = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
  const bundled = NodePath.join(here, "qml");
  return NodeFS.existsSync(NodePath.join(bundled, "T3/Tui/qmldir"))
    ? bundled
    : NodePath.join(here, "../qml");
}

/** Where a user's `shell.qml` (and extra `qml/` modules) override the default shell. */
function resolveShellConfigDir(): string {
  return (
    process.env.T3_TUI_SHELL_DIR ??
    NodePath.join(process.env.T3CODE_HOME ?? NodePath.join(NodeOS.homedir(), ".t3"), "shell", "tui")
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
  const inlineImages = detectInlineImageTransport();
  const renderer = await createCliRenderer(TUI_RENDERER_CONFIG);

  scheduleColorCapabilityLog({ log: appendLog, capabilities: () => renderer.capabilities });
  installKittyClipboardExtension(renderer, {
    tmuxPassthrough: inlineImages !== null,
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
    inlineImages,
    // Cell pixels size image previews; unknown until the terminal reports them.
    cellPixels: () =>
      renderer.resolution && renderer.width > 0 && renderer.height > 0
        ? {
            width: renderer.resolution.width / renderer.width,
            height: renderer.resolution.height / renderer.height,
          }
        : null,
    copyToClipboard: (text) => {
      renderer.copyToClipboardOSC52(text);
      return renderer.isOsc52Supported();
    },
    // ^G: hand the terminal to the editor, then take the screen back.
    runEditor: async ({ cmd, args }, file) => {
      renderer.suspend();
      try {
        await new Promise<void>((resolve, reject) => {
          const child = NodeChildProcess.spawn(cmd, [...args, file], { stdio: "inherit" });
          child.once("exit", () => resolve());
          child.once("error", reject);
        });
      } finally {
        renderer.resume();
        renderer.requestRender();
      }
    },
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
      defaultShell: NodePath.join(qmlDir, "T3/Tui/DefaultShell.qml"),
      modules: { "T3.Tui": NodePath.join(qmlDir, "T3/Tui") },
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

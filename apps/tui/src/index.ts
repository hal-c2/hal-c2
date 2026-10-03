import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import { createCliRenderer } from "@opentui/core";
import { installKittyClipboardExtension } from "@hal-c2/opentui-image";
import { runShell } from "opentui-qml";

import { buildTuiRuntime, makeTuiClient, type TuiOptions } from "./connection.ts";
import { detectInlineImageTransport } from "./terminalGraphics.ts";
import { createHost } from "./host/host.ts";
import { fileMutedThreads, MUTED_THREADS_FILE } from "./host/mutedThreads.ts";
import { enginePluginPort } from "./host/plugins.ts";
import { readUserConfig } from "./host/userConfig.ts";
import { resolveShellConfigDir } from "./shellConfigDir.ts";
import {
  connectRemoteMc,
  credentialsPath,
  findLocalMc,
  LaunchError,
  parseLaunchArgs,
  resolveMcDirs,
} from "./mcDiscovery.ts";
import { makeHttpSocketTicketMinter, makeSocketTicketMinter } from "./socketTicket.ts";
import {
  ensureColorCapabilityEnv,
  prepareTerminalViewport,
  scheduleColorCapabilityLog,
  TUI_RENDERER_CONFIG,
} from "./terminalStartup.ts";

// oxlint-disable-next-line hal-c2/no-global-process-runtime -- @hal-c2/shared/hostProcess imports node:sea, which the Bun-run TUI lacks.
const hostPlatform = process.platform;

// The Bun entry point. Started by the Node `hal-c2 tui` launcher it gets the
// server origin and a bearer via env and mints websocket URLs over the IPC
// channel to the launcher, which answers each request for the whole session.
// Started on its own (`mise run tui`) it finds the MC itself, or pairs
// with a remote one from `--url` (mcDiscovery.ts), and buys its socket tickets
// over HTTP.

const processSend = process.send as ((message: unknown) => boolean) | undefined;
const launcherTickets =
  typeof processSend === "function"
    ? makeSocketTicketMinter({ send: (message) => processSend.call(process, message) })
    : null;
if (launcherTickets) {
  process.on("message", launcherTickets.receive);
  process.on("disconnect", launcherTickets.disconnect);
}

/** Where to connect and as whom: the launcher's env, the local MC, or a paired remote. */
async function resolveConnection(): Promise<
  Pick<TuiOptions, "origin" | "bearerToken" | "environmentId" | "orchestrationProtocolVersion">
> {
  const argv = process.argv.slice(2);
  const origin = process.env.HAL_C2_TUI_ORIGIN;
  const bearerToken = process.env.HAL_C2_TUI_BEARER;
  // The launcher passes no flags (a wrapper may leave the entry's path in argv).
  if (!argv.some((arg) => arg.startsWith("--")) && (origin || bearerToken)) {
    if (!origin || !bearerToken) {
      throw new LaunchError(
        `${origin ? "HAL_C2_TUI_BEARER" : "HAL_C2_TUI_ORIGIN"} is missing: HAL_C2_TUI_ORIGIN and HAL_C2_TUI_BEARER go together.`,
      );
    }
    return { origin, bearerToken };
  }
  const args = parseLaunchArgs(argv);
  const dirs = {
    baseDir: args.baseDir,
    dev: args.dev,
    env: process.env,
    homeDir: NodeOS.homedir(),
    platform: hostPlatform,
  };
  const mc =
    args.url === undefined
      ? await findLocalMc({ dirs: resolveMcDirs(dirs) })
      : await connectRemoteMc({ url: args.url, credentialsPath: credentialsPath(dirs) });
  return {
    origin: mc.origin,
    bearerToken: mc.bearerToken,
    environmentId: mc.environmentId,
    orchestrationProtocolVersion: mc.orchestrationProtocolVersion,
  };
}

/**
 * The `HalC2.Tui` bricks ship next to the bundle (`dist/qml`, copied by the build)
 * and live at `apps/tui/qml` when running from source.
 */
function resolveQmlDir(): string {
  const here = NodePath.dirname(NodeURL.fileURLToPath(import.meta.url));
  const bundled = NodePath.join(here, "qml");
  return NodeFS.existsSync(NodePath.join(bundled, "HalC2/Tui/qmldir"))
    ? bundled
    : NodePath.join(here, "../qml");
}

async function main(): Promise<void> {
  const logPath = process.env.HAL_C2_TUI_LOG ?? "/tmp/hal-c2-tui.log";
  let connection: Awaited<ReturnType<typeof resolveConnection>>;
  try {
    connection = await resolveConnection();
  } catch (error) {
    if (!(error instanceof LaunchError)) throw error;
    process.stderr.write(`hal-c2 tui: ${error.message}\n`);
    process.exit(1);
  }
  const { origin } = connection;

  const appendLog = (line: string) => {
    try {
      NodeFS.appendFileSync(logPath, `${line}\n`);
    } catch {
      // Diagnostics only — never let logging break the UI.
    }
  };

  // Read the user's keymap and plugin locations before taking over the terminal,
  // so a broken keymap.json stops here with a readable error.
  const configDir = resolveShellConfigDir({
    env: process.env,
    homeDir: NodeOS.homedir(),
    platform: hostPlatform,
  });
  const configWarnings: string[] = [];
  const userConfig = readUserConfig({
    configDir,
    pluginPaths: process.env.HAL_C2_TUI_PLUGINS,
    warn: (message) => configWarnings.push(message),
  });

  const options: TuiOptions = {
    ...connection,
    mintSocketUrl:
      launcherTickets?.mint ??
      makeHttpSocketTicketMinter({ origin, bearerToken: connection.bearerToken }),
    logPath,
  };
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
    // The launcher says which HAL-C2 release this client is; servers behind it are offered an update.
    appVersion: process.env.HAL_C2_TUI_APP_VERSION?.trim() || null,
    dismissedUpdates: fileMutedThreads(NodePath.join(configDir, "dismissed-updates.json")),
    // Muted threads are this device's: they live beside the user's shell config.
    mutedThreads: fileMutedThreads(NodePath.join(configDir, MUTED_THREADS_FILE)),
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
      appId: "hal-c2",
      renderer,
      defaultShell: NodePath.join(qmlDir, "HalC2/Tui/DefaultShell.qml"),
      modules: { "HalC2.Tui": NodePath.join(qmlDir, "HalC2/Tui") },
      importPaths: [qmlDir],
      configDir,
      plugins: [...userConfig.plugins],
      pluginDirs: [...userConfig.pluginDirs],
      ...(userConfig.keymap ? { keymap: userConfig.keymap } : {}),
      singletons: { Shell: host.Shell, Theme: host.Theme },
      watch: process.env.HAL_C2_TUI_DEV === "1",
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
  process.stderr.write(`hal-c2 tui crashed: ${String(error)}\n`);
  process.exit(1);
});

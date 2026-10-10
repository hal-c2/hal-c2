import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import { createCliRenderer } from "@opentui/core";
import { installKittyClipboardExtension } from "@hal-c2/opentui-image";
import { runShell } from "opentui-qml";

import { makeClusterClient } from "./clusterClient.ts";
import { buildTuiRuntime, makeTuiClient, type TuiOptions } from "./connection.ts";
import { detectInlineImageTransport, inlineImageProtocol } from "./terminalGraphics.ts";
import { createHost } from "./host/host.ts";
import { fileMutedThreads, MUTED_THREADS_FILE } from "./host/mutedThreads.ts";
import { enginePluginPort, filePluginStore, PLUGIN_RECORDS_FILE } from "./host/plugins.ts";
import { movePromptCursorToEnd } from "./host/promptCursor.ts";
import { PLUGINS_DIR, readUserConfig, saveKeymapOverrides } from "./host/userConfig.ts";
import { resolveShellConfigDir } from "./shellConfigDir.ts";
import {
  connectRemoteMc,
  credentialsPath,
  findLocalMc,
  LaunchError,
  parseLaunchArgs,
  resolveMcDirs,
} from "./mcDiscovery.ts";
import { makeHttpSocketTicketMinter } from "./socketTicket.ts";
import {
  ensureColorCapabilityEnv,
  prepareTerminalViewport,
  scheduleColorCapabilityLog,
  tuiRendererConfig,
} from "./terminalStartup.ts";

// oxlint-disable-next-line hal-c2/no-global-process-runtime -- @hal-c2/shared/hostProcess imports node:sea, which the Bun-run TUI lacks.
const hostPlatform = process.platform;

// The Bun entry point (`mise run tui`). It finds the MC on this machine, or pairs
// with a remote one from `--url` (mcDiscovery.ts), and buys its socket tickets
// over HTTP.

/** Where to connect and as whom: the local MC, or a paired remote. */
async function resolveConnection(): Promise<
  Pick<TuiOptions, "origin" | "bearerToken" | "environmentId" | "orchestrationProtocolVersion">
> {
  const args = parseLaunchArgs(process.argv.slice(2));
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
 * Dev mode (`HAL_C2_TUI_DEV=1`): tell the host when one of the loaded plugin
 * files is saved. Editors write in bursts and often replace the file, so the
 * directory is watched and a burst is reported once.
 */
function watchPluginFiles(
  files: ReadonlyArray<string>,
  onChange: (file: string) => void,
): () => void {
  const timers = new Map<string, ReturnType<typeof setTimeout>>();
  const watchers = [...new Set(files.map((file) => NodePath.dirname(file)))].flatMap((dir) => {
    try {
      return [
        NodeFS.watch(dir, (_event, name) => {
          const file = name === null ? null : NodePath.join(dir, String(name));
          if (file === null || !files.includes(file)) return;
          clearTimeout(timers.get(file));
          timers.set(
            file,
            setTimeout(() => {
              timers.delete(file);
              onChange(file);
            }, 100),
          );
        }),
      ];
    } catch {
      // A directory that cannot be watched: its plugins are reloaded on restart.
      return [];
    }
  });
  return () => {
    for (const timer of timers.values()) clearTimeout(timer);
    for (const watcher of watchers) watcher.close();
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
  const appendLog = (line: string) => {
    try {
      NodeFS.appendFileSync(logPath, `${line}\n`);
    } catch {
      // Diagnostics only — never let logging break the UI.
    }
  };

  // Read the user's keymap and plugin locations before connecting or taking over
  // the terminal, so a broken keymap.json stops here with a readable error.
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

  let connection: Awaited<ReturnType<typeof resolveConnection>>;
  try {
    connection = await resolveConnection();
  } catch (error) {
    if (!(error instanceof LaunchError)) throw error;
    process.stderr.write(`hal-c2 tui: ${error.message}\n`);
    process.exit(1);
  }
  const { origin } = connection;

  const options: TuiOptions = {
    ...connection,
    mintSocketUrl: makeHttpSocketTicketMinter({ origin, bearerToken: connection.bearerToken }),
    logPath,
  };
  const runtime = buildTuiRuntime(options);
  // The other machines of a cluster are reached through this same MC, each by its environment id.
  const client = makeClusterClient(makeTuiClient(runtime, origin), (environmentId) =>
    makeTuiClient(buildTuiRuntime({ ...options, environmentId }), origin),
  );

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
  const renderer = await createCliRenderer(tuiRendererConfig());

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

  let shellRoot: Parameters<typeof movePromptCursorToEnd>[0] | null = null;
  const host = createHost({
    client,
    size: { columns: renderer.width, rows: renderer.height },
    onQuit: handleExit,
    log: appendLog,
    startupWarnings: configWarnings,
    promptCursorToEnd: (text) => {
      if (shellRoot) movePromptCursorToEnd(shellRoot, text);
    },
    features: {
      saveKeymap: (overrides) => saveKeymapOverrides(configDir, overrides),
    },
    inlineImages,
    imageProtocol: inlineImageProtocol(process.env),
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
    // `HAL_C2_TUI_APP_VERSION` names the HAL-C2 release this client is; servers behind it are offered an update.
    appVersion: process.env.HAL_C2_TUI_APP_VERSION?.trim() || null,
    dismissedUpdates: fileMutedThreads(NodePath.join(configDir, "dismissed-updates.json")),
    // Plugins turned off, and where downloaded ones came from, are this device's too.
    pluginStore: filePluginStore(NodePath.join(configDir, PLUGIN_RECORDS_FILE)),
    pluginDir: NodePath.join(configDir, PLUGINS_DIR),
    ...(process.env.HAL_C2_TUI_DEV === "1" ? { watchPlugins: watchPluginFiles } : {}),
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
    shellRoot = app.root;
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
  // force-exit: the live WebSocket would otherwise keep Bun's event loop alive,
  // so a single Ctrl+C wouldn't fully quit.
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

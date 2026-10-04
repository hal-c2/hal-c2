// @effect-diagnostics globalFetch:off
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import type { PropertyMap } from "opentui-qml";

import type { StatusKind } from "../store.ts";
import {
  memoryPluginStore,
  type PluginPort,
  type PluginStore,
  type TuiPluginsState,
} from "./plugins.ts";

/** The most a downloaded plugin file may weigh. */
const MAX_PLUGIN_BYTES = 512 * 1024;

export interface PluginCatalogOptions {
  readonly state: PropertyMap;
  readonly status: (text: string, kind?: StatusKind) => void;
  readonly store?: PluginStore | undefined;
  /** Where downloaded plugin files are kept (the config directory's `plugins`); null: nowhere. */
  readonly pluginDir?: string | null | undefined;
  /** Fetch a plugin file's text (the default uses `fetch`). */
  readonly download?: ((url: string) => Promise<string>) | undefined;
  /**
   * Dev mode: call `onChange(file)` when one of these plugin files is saved;
   * returns how to stop. Absent outside dev mode, where nothing is watched.
   */
  readonly watch?:
    | ((files: ReadonlyArray<string>, onChange: (file: string) => void) => () => void)
    | undefined;
}

const reason = (error: unknown) => (error instanceof Error ? error.message : String(error));

async function fetchPlugin(url: string): Promise<string> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`.trim());
  return response.text();
}

/** `https://host/path/team-status.qml?x=1` → `team-status.qml`; null when the URL names no QML file. */
function pluginFileName(url: URL): string | null {
  const name = NodePath.posix.basename(url.pathname);
  return /^[\w.-]+\.qml$/.test(name) ? name : null;
}

/**
 * The plugins this client has: what the QML engine loaded, the ones the user
 * turned off (kept on disk, not loaded, remembered across restarts) and where
 * a downloaded one came from. Published under `plugins`.
 */
export function createPluginCatalog(options: PluginCatalogOptions) {
  const { state } = options;
  const store = options.store ?? memoryPluginStore();
  let port: PluginPort | null = null;
  let records = store.load();
  let stopWatching: (() => void) | null = null;
  const pending = new Set<Promise<unknown>>();
  const track = <T>(promise: Promise<T>): Promise<T> => {
    pending.add(promise);
    const done = () => pending.delete(promise);
    promise.then(done, done);
    return promise;
  };

  const save = (next: typeof records) => {
    records = next;
    store.save(next);
  };

  const publish = () => {
    const items = port?.list() ?? [];
    state.set("plugins", {
      items,
      disabled: records.disabled,
      sources: Object.fromEntries(
        items.flatMap((plugin) =>
          plugin.file !== null && records.sources[plugin.file] !== undefined
            ? [[plugin.id, records.sources[plugin.file]!]]
            : [],
        ),
      ),
    } satisfies TuiPluginsState);
    // Dev mode follows the files of what is loaded now.
    if (options.watch) {
      stopWatching?.();
      const files = items.flatMap((plugin) => (plugin.file === null ? [] : [plugin.file]));
      stopWatching = files.length > 0 ? options.watch(files, (file) => void reload(file)) : null;
    }
  };

  const disable = (id: string) => {
    const plugin = port?.list().find((candidate) => candidate.id === id);
    if (!port || !plugin) return;
    if (plugin.file === null) {
      // Nothing to load it from again: it would be gone, not disabled.
      options.status(`"${id}" is built into this client and cannot be disabled.`, "error");
      return;
    }
    port.remove(id);
    save({
      ...records,
      disabled: [...records.disabled.filter((entry) => entry.id !== id), { id, file: plugin.file }],
    });
    publish();
    options.status(`Plugin "${id}" disabled.`, "success");
  };

  const enable = (id: string) => {
    const entry = records.disabled.find((candidate) => candidate.id === id);
    if (!port || !entry) return;
    save({ ...records, disabled: records.disabled.filter((candidate) => candidate.id !== id) });
    publish();
    void track(
      port.load(entry.file).then(() => {
        publish();
        const loaded = port!.list().some((plugin) => plugin.file === entry.file);
        options.status(
          loaded ? `Plugin "${id}" enabled.` : `Plugin "${id}" could not be loaded.`,
          loaded ? "success" : "error",
        );
      }),
    );
  };

  const reload = (file: string) => {
    if (!port?.reload) return Promise.resolve();
    const id = port.list().find((plugin) => plugin.file === file)?.id ?? NodePath.basename(file);
    return track(
      port.reload(file).then((reloaded) => {
        publish();
        options.status(
          reloaded
            ? `Plugin "${id}" reloaded.`
            : `Plugin "${id}" did not load: the last working version keeps running.`,
          reloaded ? "success" : "error",
        );
      }),
    );
  };

  /** Download a plugin file, keep it in the plugin directory and load it. */
  const install = (address: string) => {
    let url: URL;
    try {
      url = new URL(address);
    } catch {
      options.status(`"${address}" is not a URL.`, "error");
      return;
    }
    const name = pluginFileName(url);
    if ((url.protocol !== "https:" && url.protocol !== "http:") || name === null) {
      options.status("A plugin URL is an http(s) address of a .qml file.", "error");
      return;
    }
    const dir = options.pluginDir ?? null;
    if (!port || dir === null) {
      options.status("This client has no plugin directory to keep the plugin in.", "error");
      return;
    }
    const file = NodePath.join(dir, name);
    if (
      NodeFS.existsSync(file) &&
      records.sources[file] !== url.href &&
      !records.disabled.some((entry) => entry.file === file)
    ) {
      options.status(`A plugin file named ${name} is already installed.`, "error");
      return;
    }
    options.status(`Downloading ${name}…`, "busy");
    const active = port;
    void track(
      (options.download ?? fetchPlugin)(url.href).then(
        async (source) => {
          if (source.trim() === "" || Buffer.byteLength(source) > MAX_PLUGIN_BYTES) {
            options.status(
              `The plugin could not be downloaded: ${name} is ${source.trim() === "" ? "empty" : "too large"}.`,
              "error",
            );
            return;
          }
          NodeFS.mkdirSync(dir, { recursive: true });
          NodeFS.writeFileSync(file, source);
          // The loader is the check: a file that is not a plugin, or does not parse, is refused.
          const reloaded = active.list().some((plugin) => plugin.file === file);
          if (reloaded && active.reload) await active.reload(file);
          else await active.load(file);
          const loaded = active.list().find((plugin) => plugin.file === file);
          if (!loaded) {
            NodeFS.rmSync(file, { force: true });
            publish();
            options.status(`${name} is not a plugin this client can load.`, "error");
            return;
          }
          save({ ...records, sources: { ...records.sources, [file]: url.href } });
          publish();
          options.status(`Plugin "${loaded.id}" loaded from ${url.host}.`, "success");
        },
        (error: unknown) =>
          options.status(`The plugin could not be downloaded: ${reason(error)}`, "error"),
      ),
    );
  };

  return {
    /** The QML engine is up: drop what the user turned off, then list what is loaded. */
    attach: (next: PluginPort) => {
      port = next;
      for (const entry of records.disabled) {
        const loaded = next.list().find((plugin) => plugin.file === entry.file);
        if (loaded) next.remove(loaded.id);
      }
      publish();
    },
    publish,
    port: () => port,
    disable,
    enable,
    install,
    reload,
    settled: async () => {
      while (pending.size > 0) await Promise.allSettled(pending);
    },
    dispose: () => {
      stopWatching?.();
      stopWatching = null;
    },
  };
}

export type PluginCatalog = ReturnType<typeof createPluginCatalog>;

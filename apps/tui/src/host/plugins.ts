import * as NodeFS from "node:fs";
import * as NodePath from "node:path";

import {
  addPlugin,
  isPluginDocument,
  listPlugins,
  unregisterPlugin,
  type PluginInfo,
  type QmlEngine,
} from "opentui-qml";

/** One loaded UI plugin, as `Shell.state.plugins.items` lists it. */
export interface TuiPluginInfo {
  readonly id: string;
  /** `qml` for a plugin file, `script` for one registered from TypeScript. */
  readonly kind: "qml" | "script";
  readonly file: string | null;
  readonly order: number;
}

/** A plugin the user turned off: its file stays where it is and is not loaded. */
export interface DisabledPlugin {
  readonly id: string;
  readonly file: string;
}

export interface TuiPluginsState {
  readonly items: ReadonlyArray<TuiPluginInfo>;
  /** Installed and turned off: kept on disk, contributing nothing. */
  readonly disabled: ReadonlyArray<DisabledPlugin>;
  /** Where a plugin was downloaded from, by plugin id. */
  readonly sources: Readonly<Record<string, string>>;
}

/** What the host needs from the QML engine to list, load and remove plugins. */
export interface PluginPort {
  readonly list: () => ReadonlyArray<TuiPluginInfo>;
  readonly remove: (id: string) => boolean;
  /** Load a plugin file; failures reach the engine's `onError`, never throw. */
  readonly load: (file: string) => Promise<void>;
  /**
   * Load a plugin file again in place of the plugin it was loaded as. The new
   * version is read first: when it does not parse, or is no plugin, the error
   * is reported and the running one is left alone (false).
   */
  readonly reload?: (file: string) => Promise<boolean>;
}

const toInfo = (info: PluginInfo): TuiPluginInfo => ({
  id: info.id,
  kind: info.kind === "qml" ? "qml" : "script",
  file: info.file ?? null,
  order: info.order,
});

export function enginePluginPort(engine: QmlEngine): PluginPort {
  const list = () => (engine.isDestroyed ? [] : listPlugins(engine).map(toInfo));
  return {
    list,
    remove: (id) => !engine.isDestroyed && unregisterPlugin(engine, id),
    load: (file) => addPlugin(engine, NodePath.resolve(file)),
    reload: async (file) => {
      if (engine.isDestroyed) return false;
      const path = NodePath.resolve(file);
      const running = list().find((plugin) => plugin.file === path);
      engine.invalidate(path);
      try {
        const component = await engine.loadFile(path);
        if (!isPluginDocument(component)) {
          throw new Error(`${path}: root object is not a Plugin`);
        }
      } catch (error) {
        engine.reportError(error, `plugin "${running?.id ?? path}" (reload)`);
        return false;
      }
      if (running) unregisterPlugin(engine, running.id);
      await addPlugin(engine, path);
      return list().some((plugin) => plugin.file === path);
    },
  };
}

/** What this device remembers about its plugins between runs. */
export interface PluginRecords {
  readonly disabled: ReadonlyArray<DisabledPlugin>;
  /** The URL a downloaded plugin file came from, by file path. */
  readonly sources: Readonly<Record<string, string>>;
}

export interface PluginStore {
  readonly load: () => PluginRecords;
  readonly save: (records: PluginRecords) => void;
}

export const PLUGIN_RECORDS_FILE = "plugins.json";
const NO_RECORDS: PluginRecords = { disabled: [], sources: {} };

/** Kept only while the client runs (the default, and what tests start from). */
export function memoryPluginStore(initial: PluginRecords = NO_RECORDS): PluginStore {
  let current = initial;
  return {
    load: () => current,
    save: (records) => {
      current = records;
    },
  };
}

/** Kept in a JSON file beside the user's shell config; a missing or broken file is empty. */
export function filePluginStore(path: string): PluginStore {
  return {
    load: () => {
      try {
        const parsed = JSON.parse(NodeFS.readFileSync(path, "utf8")) as Partial<PluginRecords>;
        return {
          disabled: Array.isArray(parsed.disabled)
            ? parsed.disabled.filter(
                (entry) => typeof entry?.id === "string" && typeof entry?.file === "string",
              )
            : [],
          sources:
            typeof parsed.sources === "object" && parsed.sources !== null ? parsed.sources : {},
        };
      } catch {
        return NO_RECORDS;
      }
    },
    save: (records) => {
      try {
        NodeFS.mkdirSync(NodePath.dirname(path), { recursive: true });
        NodeFS.writeFileSync(path, `${JSON.stringify(records, null, 2)}\n`);
      } catch {
        // The change still holds for this run.
      }
    },
  };
}

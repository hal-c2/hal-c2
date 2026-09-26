import * as NodePath from "node:path";

import {
  addPlugin,
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

export interface TuiPluginsState {
  readonly items: ReadonlyArray<TuiPluginInfo>;
}

/** What the host needs from the QML engine to list, load and remove plugins. */
export interface PluginPort {
  readonly list: () => ReadonlyArray<TuiPluginInfo>;
  readonly remove: (id: string) => boolean;
  /** Load a plugin file; failures reach the engine's `onError`, never throw. */
  readonly load: (file: string) => Promise<void>;
}

const toInfo = (info: PluginInfo): TuiPluginInfo => ({
  id: info.id,
  kind: info.kind === "qml" ? "qml" : "script",
  file: info.file ?? null,
  order: info.order,
});

export function enginePluginPort(engine: QmlEngine): PluginPort {
  return {
    list: () => (engine.isDestroyed ? [] : listPlugins(engine).map(toInfo)),
    remove: (id) => !engine.isDestroyed && unregisterPlugin(engine, id),
    load: (file) => addPlugin(engine, NodePath.resolve(file)),
  };
}

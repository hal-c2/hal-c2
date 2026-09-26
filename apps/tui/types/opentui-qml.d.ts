// The slice of opentui-qml's API the TUI uses. opentui-qml ships TypeScript
// source that does not compile under this repo's stricter flags
// (exactOptionalPropertyTypes, erasableSyntaxOnly, untyped solid-js), so
// tsconfig `paths` points here instead of at that source. Extend it as you
// use more; delete it once opentui-qml ships declarations.
import type { CliRenderer, CliRendererConfig } from "@opentui/core";

export interface PropertyMap {
  set(key: string, value: unknown): void;
  insert(key: string, value: unknown): void;
  get(key: string): unknown;
  value(key: string): unknown;
  contains(key: string): boolean;
  clear(key: string): void;
  keys(): string[];
  toJSON(): Record<string, unknown>;
  readonly [key: string]: unknown;
}

export function createPropertyMap(initial?: Record<string, unknown>): PropertyMap;
export function createStore<T extends object>(initial: T): T;

export interface QmlObject {
  readonly typeName: string;
  readonly children: QmlObject[];
  readonly parent: QmlObject | null;
  readonly proxy: any;
  readonly isDestroyed: boolean;
  readonly component: { readonly ids: Map<string, QmlObject> };
  get(name: string): unknown;
  /** Read without tracking (outside bindings). */
  peek(name: string): unknown;
  set(name: string, value: unknown): void;
  emit(signal: string, ...args: unknown[]): void;
  destroy(): void;
}

export interface QmlEngine {
  readonly renderer: CliRenderer;
  readonly isDestroyed: boolean;
}

export interface PluginInfo {
  readonly id: string;
  readonly order: number;
  readonly kind: "ts" | "qml";
  readonly file?: string;
}

export function listPlugins(engine: QmlEngine): PluginInfo[];
export function unregisterPlugin(engine: QmlEngine, id: string): boolean;
/** Register a plugin spec or load a QML plugin file; failures reach `onError`. */
export function addPlugin(engine: QmlEngine, plugin: object | string): Promise<void>;
export function parseQml(source: string, filename?: string): unknown;
export class QmlSyntaxError extends Error {}

export interface RunQmlOptions {
  renderer?: CliRenderer;
  rendererConfig?: CliRendererConfig;
  context?: Record<string, unknown>;
  plugins?: unknown[];
  pluginDirs?: string[];
  keymap?: Record<string, unknown>;
  basePath?: string;
  importPaths?: string[];
  singletons?: Record<string, unknown>;
  onWarning?: (message: string) => void;
  onError?: (error: unknown, context?: string) => void;
}

export interface QmlApp {
  engine: QmlEngine;
  root: QmlObject;
  renderer: CliRenderer;
  destroy(): void;
}

export interface RunShellOptions extends RunQmlOptions {
  appId: string;
  defaultShell: string;
  modules?: Record<string, string>;
  configDir?: string;
  userShell?: string;
  watch?: boolean;
  errorOverlay?: boolean;
}

export interface ShellApp extends QmlApp {
  reload(): Promise<void>;
  readonly usingUserShell: boolean;
  readonly userShellPath: string;
  readonly configDir: string;
  readonly lastError: Error | null;
  readonly generation: number;
  on(event: "generation", cb: (generation: number) => void): () => void;
  on(event: "error", cb: (error: Error) => void): () => void;
}

export function runShell(options: RunShellOptions): Promise<ShellApp>;

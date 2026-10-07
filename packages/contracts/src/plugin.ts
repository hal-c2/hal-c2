import * as Schema from "effect/Schema";

import { NonNegativeInt, TrimmedNonEmptyString } from "./baseSchemas.ts";

/**
 * Plugin packages and the MC's plugin methods.
 *
 * A package is a directory, `<id>/plugin.json` beside an optional `mc/` (Elixir
 * source the MC compiles), optional QML files the MC serves to its clients, and
 * assets. It can live outside this repository: the manifest below is the whole
 * contract between a package and HAL-C2, and `pluginManifestJsonSchema` is the same
 * contract as a JSON Schema for editors and other languages.
 */

/** The plugin API this contract describes; the MC refuses other versions. */
export const PLUGIN_API_VERSION = 1;

// Authors write the manifest by hand, so its strings are taken as written (no
// trimming transform) and its checks survive into the JSON Schema.
const NonEmpty = Schema.String.check(Schema.isNonEmpty());

const PluginId = NonEmpty.check(Schema.isPattern(/^[a-z][a-z0-9-]*$/)).annotate({
  description:
    "Lowercase letters, digits and dashes, starting with a letter. The package's directory name.",
});

/** A path inside the package, such as `ui/ReviewsPage.qml`; never absolute, never `..`. */
const PackagePath = NonEmpty.check(
  Schema.isPattern(/^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[\w./-]+$/),
).annotate({ description: "A relative path inside the package." });

/**
 * What a plugin may ask the MC for. Granting one lets the plugin call that part of
 * the host API (`HalC2.Plugins.Host`); calls outside what was granted are refused.
 * An MC part is Elixir running inside the MC, so this gates the host API rather
 * than sandboxing the code: the consent says so.
 */
export const PluginPermissionId = Schema.Literals([
  "projects:read",
  "pullRequests:read",
  "pullRequests:write",
  "threads:read",
  "threads:create",
  "agentTools",
]);
export type PluginPermissionId = typeof PluginPermissionId.Type;

export const PluginPermissionRequest = Schema.Struct({
  id: PluginPermissionId,
  reason: NonEmpty.annotate({ description: "Why the plugin needs it, shown at consent." }),
});
export type PluginPermissionRequest = typeof PluginPermissionRequest.Type;

const SettingBase = {
  key: NonEmpty,
  label: NonEmpty,
  description: Schema.optionalKey(Schema.String),
} as const;

const PluginSettingOption = Schema.Struct({
  value: NonEmpty,
  label: NonEmpty,
  disabled: Schema.optionalKey(Schema.Boolean),
});

/** One field of a plugin's settings; the MC checks saved values against its type. */
export const PluginSettingField = Schema.Union([
  Schema.Struct({
    ...SettingBase,
    type: Schema.Literal("text"),
    default: Schema.optionalKey(Schema.String),
  }),
  Schema.Struct({
    ...SettingBase,
    type: Schema.Literal("longText"),
    default: Schema.optionalKey(Schema.String),
  }),
  Schema.Struct({ ...SettingBase, type: Schema.Literal("secret") }),
  Schema.Struct({
    ...SettingBase,
    type: Schema.Literal("boolean"),
    default: Schema.optionalKey(Schema.Boolean),
  }),
  Schema.Struct({
    ...SettingBase,
    type: Schema.Literal("number"),
    default: Schema.optionalKey(Schema.Finite),
  }),
  Schema.Struct({
    ...SettingBase,
    type: Schema.Literal("choice"),
    options: Schema.Array(PluginSettingOption),
    default: Schema.optionalKey(Schema.String),
  }),
  Schema.Struct({
    ...SettingBase,
    type: Schema.Literal("list"),
    default: Schema.optionalKey(Schema.Array(Schema.String)),
  }),
  Schema.Struct({
    ...SettingBase,
    type: Schema.Literal("object"),
    default: Schema.optionalKey(Schema.Unknown),
  }),
]);
export type PluginSettingField = typeof PluginSettingField.Type;

/** A page the user switches to with the shell's tabs. */
export const PluginPage = Schema.Struct({
  id: NonEmpty,
  title: NonEmpty,
  icon: Schema.optionalKey(NonEmpty),
  qml: PackagePath,
});
export type PluginPage = typeof PluginPage.Type;

/**
 * How a kind of thread the plugin starts looks: `rowMark` beside its row in the
 * thread list, `header` above its conversation. Each is a QML component given
 * `thread` (`{id, title, plugin}`) and `plugin` (its PluginContext).
 */
export const PluginThreadKind = Schema.Struct({
  kind: NonEmpty,
  label: NonEmpty,
  rowMark: Schema.optionalKey(PackagePath),
  header: Schema.optionalKey(PackagePath),
});
export type PluginThreadKind = typeof PluginThreadKind.Type;

/** Content for one of the shell's named slots (`statusbar`, `sidebar.sections`, ...). */
export const PluginSlotContribution = Schema.Struct({
  slot: NonEmpty,
  qml: PackagePath,
  order: Schema.optionalKey(Schema.Int),
});
export type PluginSlotContribution = typeof PluginSlotContribution.Type;

/**
 * What a running plugin adds to its environment's clients. Each part is one
 * self-contained QML file: clients fetch only the files named here, so a part
 * cannot import the package's other files.
 */
export const PluginContributions = Schema.Struct({
  pages: Schema.optionalKey(Schema.Array(PluginPage)),
  threadKinds: Schema.optionalKey(Schema.Array(PluginThreadKind)),
  slots: Schema.optionalKey(Schema.Array(PluginSlotContribution)),
  /** The plugin's own settings page; without it clients build one from `settings`. */
  settingsPage: Schema.optionalKey(PackagePath),
});
export type PluginContributions = typeof PluginContributions.Type;

export const PluginAuthor = Schema.Struct({
  name: NonEmpty,
  url: Schema.optionalKey(NonEmpty),
});

export const PluginScreenshot = Schema.Struct({
  path: PackagePath,
  caption: Schema.optionalKey(Schema.String),
});

/** `plugin.json`, the root of a package. */
export const PluginManifest = Schema.Struct({
  $schema: Schema.optionalKey(Schema.String),
  id: PluginId,
  name: NonEmpty,
  version: NonEmpty,
  apiVersion: Schema.Int,
  description: NonEmpty,
  author: Schema.optionalKey(PluginAuthor),
  homepage: Schema.optionalKey(NonEmpty),
  license: Schema.optionalKey(NonEmpty),
  icon: Schema.optionalKey(PackagePath),
  screenshots: Schema.optionalKey(Schema.Array(PluginScreenshot)),
  permissions: Schema.optionalKey(Schema.Array(PluginPermissionRequest)),
  settings: Schema.optionalKey(Schema.Array(PluginSettingField)),
  contributes: Schema.optionalKey(PluginContributions),
});
export type PluginManifest = typeof PluginManifest.Type;

/** The manifest as a standalone JSON Schema; published as `packages/contracts/plugin.schema.json`. */
export const pluginManifestJsonSchema = (() => {
  const document = Schema.toJsonSchemaDocument(PluginManifest, { onExcessProperty: "error" });
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    title: "HAL-C2 plugin manifest",
    ...document.schema,
    ...(Object.keys(document.definitions).length > 0 ? { $defs: document.definitions } : {}),
  };
})();

export const PluginStatus = Schema.Literals([
  "running",
  "disabled",
  "failed",
  "error",
  "incompatible",
  "awaitingConsent",
]);
export type PluginStatus = typeof PluginStatus.Type;

/** One plugin as `plugins.list` and the `plugins` shape give it. */
export const PluginEntry = Schema.Struct({
  id: TrimmedNonEmptyString,
  name: Schema.String,
  version: Schema.NullOr(Schema.String),
  /** The first of `kinds`, null for a package of UI parts only. */
  kind: Schema.NullOr(Schema.String),
  kinds: Schema.Array(Schema.String),
  apiVersion: Schema.NullOr(Schema.Int),
  source: Schema.Literals(["bundled", "file", "package"]),
  file: Schema.NullOr(Schema.String),
  description: Schema.NullOr(Schema.String),
  author: Schema.NullOr(PluginAuthor),
  homepage: Schema.NullOr(Schema.String),
  license: Schema.NullOr(Schema.String),
  icon: Schema.NullOr(PackagePath),
  screenshots: Schema.Array(PluginScreenshot),
  enabled: Schema.Boolean,
  status: PluginStatus,
  error: Schema.NullOr(Schema.String),
  reloadError: Schema.NullOr(Schema.String),
  lastError: Schema.NullOr(Schema.String),
  restarts: NonNegativeInt,
  /** Whether the plugin runs Elixir inside the MC, with the MC's own access. */
  runsCode: Schema.Boolean,
  settingsSchema: Schema.Array(Schema.Unknown),
  settings: Schema.Record(Schema.String, Schema.Unknown),
  permissions: Schema.Array(
    Schema.Struct({
      id: Schema.String,
      label: Schema.String,
      reason: Schema.optionalKey(Schema.String),
      granted: Schema.Boolean,
    }),
  ),
  /** What a refused host call last asked for, by permission. */
  denied: Schema.Array(Schema.String),
  contributes: PluginContributions,
  /** Changes whenever the package's files change; clients reload its UI parts. */
  revision: Schema.NullOr(Schema.String),
});
export type PluginEntry = typeof PluginEntry.Type;

/**
 * The MC's plugin methods, over the protocol 3 `rpc` frame. They are the MC's own
 * (the TypeScript server never served plugins), so they sit outside `WS_METHODS`.
 */
export const PLUGIN_METHODS = {
  list: "plugins.list",
  rescan: "plugins.rescan",
  enable: "plugins.enable",
  disable: "plugins.disable",
  restart: "plugins.restart",
  saveSettings: "plugins.saveSettings",
  call: "plugins.call",
  file: "plugins.file",
} as const;

export const PluginEnableInput = Schema.Struct({
  id: TrimmedNonEmptyString,
  /** The permissions the user accepted; enabling fails while one asked for is missing. */
  acceptPermissions: Schema.optional(Schema.Array(Schema.String)),
});

export const PluginIdInput = Schema.Struct({ id: TrimmedNonEmptyString });

export const PluginSaveSettingsInput = Schema.Struct({
  id: TrimmedNonEmptyString,
  settings: Schema.Record(Schema.String, Schema.Unknown),
});

/** Asks a running plugin's MC part (`HalC2.Plugins.Extension.call/3`). */
export const PluginCallInput = Schema.Struct({
  id: TrimmedNonEmptyString,
  method: TrimmedNonEmptyString,
  input: Schema.optional(Schema.Unknown),
});

export const PluginFileInput = Schema.Struct({ id: TrimmedNonEmptyString, path: PackagePath });

export const PluginFileResult = Schema.Struct({
  path: PackagePath,
  encoding: Schema.Literals(["utf8", "base64"]),
  content: Schema.String,
  revision: Schema.String,
});
export type PluginFileResult = typeof PluginFileResult.Type;

export const PluginsListResult = Schema.Struct({ plugins: Schema.Array(PluginEntry) });

export const PluginError = Schema.Struct({
  _tag: Schema.Literals([
    "PluginNotFound",
    "PluginUnavailable",
    "PluginNotRunning",
    "PluginSettingsInvalid",
    "PluginConsentRequired",
    "PluginCallFailed",
    "PluginFileNotFound",
  ]),
  message: Schema.String,
});

/**
 * Subscription shapes, named by environment: `{type: "plugins"}` pushes
 * `{t: "plugins", plugins}` at once and on every change; `{type: "plugin", id, topic}`
 * pushes `{t: "plugin", topic, value}` with what the plugin last published on
 * `topic` (null before it has), at once and on every publish.
 */
export const PluginsShape = Schema.Struct({
  type: Schema.Literal("plugins"),
  environment: TrimmedNonEmptyString,
});
export const PluginTopicShape = Schema.Struct({
  type: Schema.Literal("plugin"),
  environment: TrimmedNonEmptyString,
  id: TrimmedNonEmptyString,
  topic: TrimmedNonEmptyString,
});

/** What a thread a plugin started carries (`OrchestrationV2AppThread.plugin`). */
export const ThreadPluginMark = Schema.Struct({
  id: TrimmedNonEmptyString,
  kind: TrimmedNonEmptyString,
  /** False keeps the thread out of the thread list; it still opens by id. */
  listed: Schema.Boolean,
});
export type ThreadPluginMark = typeof ThreadPluginMark.Type;

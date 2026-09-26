import * as NodePath from "@effect/platform-node/NodePath";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, describe, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import * as DesktopEnvironment from "./DesktopEnvironment.ts";
import * as DesktopConfig from "./DesktopConfig.ts";

const defaultInput = {
  dirname: "/repo/apps/desktop/dist-electron",
  homeDirectory: "/Users/alice",
  platform: "darwin",
  processArch: "arm64",
  appVersion: "0.0.22",
  appPath: "/Applications/HAL-C2.app/Contents/Resources/app.asar",
  isPackaged: false,
  resourcesPath: "/Applications/HAL-C2.app/Contents/Resources",
  runningUnderArm64Translation: false,
} satisfies DesktopEnvironment.MakeDesktopEnvironmentInput;

const makeEnvironmentLayer = (
  overrides: Partial<DesktopEnvironment.MakeDesktopEnvironmentInput> = {},
  env: Record<string, string | undefined> = {},
) =>
  DesktopEnvironment.layer({
    ...defaultInput,
    ...overrides,
  }).pipe(
    Layer.provide(
      Layer.mergeAll(NodeServices.layer, NodePath.layerPosix, DesktopConfig.layerTest(env)),
    ),
  );

const makeEnvironment = (
  overrides: Partial<DesktopEnvironment.MakeDesktopEnvironmentInput> = {},
  env: Record<string, string | undefined> = {},
) =>
  DesktopEnvironment.DesktopEnvironment.pipe(Effect.provide(makeEnvironmentLayer(overrides, env)));

describe("DesktopEnvironment", () => {
  it.effect("derives state paths and development identity inside Effect", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment(
        {},
        {
          HAL_C2_HOME: " /tmp/hal-c2 ",
          HAL_C2_COMMIT_HASH: " 0123456789abcdef ",
          HAL_C2_PORT: "4949",
          VITE_DEV_SERVER_URL: "http://localhost:5173",
          HAL_C2_DEV_REMOTE_HAL_C2_SERVER_ENTRY_PATH: " /remote/server.mjs ",
          HAL_C2_OTLP_TRACES_URL: " http://127.0.0.1:4318/v1/traces ",
          HAL_C2_OTLP_METRICS_URL: " http://127.0.0.1:4318/v1/metrics ",
          HAL_C2_OTLP_LOGS_URL: " http://127.0.0.1:4318/v1/logs ",
          HAL_C2_OTLP_EXPORT_INTERVAL_MS: "2500",
          HAL_C2_OTLP_HEADERS: "authorization=Basic%20abc%3D%3D,x-tenant=hal-c2",
          HAL_C2_OTLP_PROTOCOL: "http/protobuf",
        },
      );

      assert.equal(environment.isDevelopment, true);
      assert.equal(environment.appDataDirectory, "/Users/alice/Library/Application Support");
      // An explicit root has one profile, even in development.
      assert.deepEqual(environment.halC2Root, Option.some("/tmp/hal-c2"));
      assert.equal(environment.storageProfile, "hal-c2");
      assert.equal(environment.desktopSettingsPath, "/tmp/hal-c2/config/desktop-settings.json");
      assert.equal(environment.clientSettingsPath, "/tmp/hal-c2/config/client-settings.json");
      assert.equal(
        environment.savedEnvironmentRegistryPath,
        "/tmp/hal-c2/data/saved-environments.json",
      );
      assert.equal(environment.serverSettingsPath, "/tmp/hal-c2/config/settings.json");
      assert.equal(environment.logDir, "/tmp/hal-c2/state/logs");
      assert.equal(environment.browserArtifactsDir, "/tmp/hal-c2/data/browser-artifacts");
      assert.equal(environment.rootDir, "/repo");
      assert.equal(environment.appRoot, "/repo");
      assert.equal(environment.serverRoot, "/repo");
      assert.equal(environment.backendEntryPath, "/repo/apps/server/dist/bin.mjs");
      assert.equal(environment.backendCwd, "/repo");
      assert.equal(environment.appUserModelId, "io.github.halc2.app.dev");
      assert.equal(environment.linuxWmClass, "hal-c2-dev");
      assert.equal(environment.linuxDesktopEntryName, "io.github.halc2.HalC2.Development.desktop");
      assert.deepEqual(
        Option.map(environment.devServerUrl, (url) => url.href),
        Option.some("http://localhost:5173/"),
      );
      assert.deepEqual(
        environment.devRemoteHalC2ServerEntryPath,
        Option.some("/remote/server.mjs"),
      );
      assert.deepEqual(environment.configuredBackendPort, Option.some(4949));
      assert.deepEqual(environment.commitHashOverride, Option.some("0123456789abcdef"));
      assert.deepEqual(environment.otlpTracesUrl, Option.some("http://127.0.0.1:4318/v1/traces"));
      assert.deepEqual(environment.otlpMetricsUrl, Option.some("http://127.0.0.1:4318/v1/metrics"));
      assert.deepEqual(environment.otlpLogsUrl, Option.some("http://127.0.0.1:4318/v1/logs"));
      assert.equal(environment.otlpExportIntervalMs, 2500);
      assert.deepEqual(
        environment.otlpHeaders,
        Option.some({
          authorization: "Basic abc==",
          "x-tenant": "hal-c2",
        }),
      );
      assert.equal(environment.otlpProtocol, "http/protobuf");
    }),
  );

  it.effect("files each desktop path under the XDG kind it belongs to", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment(
        { platform: "linux", homeDirectory: "/home/alice" },
        { XDG_RUNTIME_DIR: "/run/user/1000", XDG_CACHE_HOME: "relative/cache" },
      );

      assert.deepEqual(environment.halC2Root, Option.none());
      assert.deepEqual(environment.dirs, {
        config: "/home/alice/.config/hal-c2",
        data: "/home/alice/.local/share/hal-c2",
        state: "/home/alice/.local/state/hal-c2",
        cache: "/home/alice/.cache/hal-c2",
        runtime: "/run/user/1000/hal-c2",
      });
      assert.equal(
        environment.desktopSettingsPath,
        "/home/alice/.config/hal-c2/desktop-settings.json",
      );
      assert.equal(
        environment.clientSettingsPath,
        "/home/alice/.config/hal-c2/client-settings.json",
      );
      assert.equal(environment.serverSettingsPath, "/home/alice/.config/hal-c2/settings.json");
      assert.equal(
        environment.savedEnvironmentRegistryPath,
        "/home/alice/.local/share/hal-c2/saved-environments.json",
      );
      assert.equal(
        environment.browserArtifactsDir,
        "/home/alice/.local/share/hal-c2/browser-artifacts",
      );
      assert.equal(environment.logDir, "/home/alice/.local/state/hal-c2/logs");
      assert.equal(environment.otlpProtocol, "http/json");
    }),
  );

  it.effect("honours absolute XDG variables and ignores a legacy HAL_C2_HOME", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment(
        { platform: "linux", homeDirectory: "/home/alice" },
        {
          HAL_C2_HOME: "/home/alice/.hal-c2",
          XDG_CONFIG_HOME: "/xdg/config",
          XDG_DATA_HOME: "/xdg/data",
          XDG_STATE_HOME: "/xdg/state",
          XDG_CACHE_HOME: "/xdg/cache",
        },
      );

      assert.deepEqual(environment.halC2Root, Option.none());
      assert.deepEqual(environment.dirs, {
        config: "/xdg/config/hal-c2",
        data: "/xdg/data/hal-c2",
        state: "/xdg/state/hal-c2",
        cache: "/xdg/cache/hal-c2",
        runtime: "/xdg/state/hal-c2",
      });
    }),
  );

  it.effect("uses the XDG defaults on macOS", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment();

      assert.equal(environment.dirs.config, "/Users/alice/.config/hal-c2");
      assert.equal(environment.logDir, "/Users/alice/.local/state/hal-c2/logs");
    }),
  );

  it.effect("uses the packaged Windows server sidecar as the backend root", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment({
        platform: "win32",
        isPackaged: true,
        appPath: "/install/resources/app.asar",
        resourcesPath: "/install/resources",
      });

      assert.equal(environment.appRoot, "/install/resources/app.asar");
      assert.equal(environment.serverRoot, "/install/resources/server.asar");
      assert.equal(
        environment.backendEntryPath,
        "/install/resources/server.asar/apps/server/dist/bin.mjs",
      );
      assert.equal(
        environment.clientAssetsDir,
        "/install/resources/server.asar/apps/server/dist/client",
      );
    }),
  );

  it.effect("uses the stable desktop entry as the packaged Linux portal identity", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment({
        platform: "linux",
        isPackaged: true,
        appPath: "/tmp/.mount_hal-c2/resources/app.asar",
        resourcesPath: "/tmp/.mount_hal-c2/resources",
      });

      assert.equal(environment.linuxDesktopEntryName, "io.github.halc2.HalC2.desktop");
    }),
  );

  it.effect("keeps implicit development state separate from production state", () =>
    Effect.gen(function* () {
      const development = yield* makeEnvironment(
        {},
        { VITE_DEV_SERVER_URL: "http://localhost:5173" },
      );
      const production = yield* makeEnvironment();

      assert.equal(development.storageProfile, "hal-c2-dev");
      assert.equal(development.dirs.data, "/Users/alice/.local/share/hal-c2-dev");
      assert.equal(production.storageProfile, "hal-c2");
      assert.equal(production.dirs.data, "/Users/alice/.local/share/hal-c2");
    }),
  );

  it.effect("uses a configured app user model id override", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment(
        {},
        {
          HAL_C2_DESKTOP_APP_USER_MODEL_ID: " io.github.halc2.app.dev.local ",
          VITE_DEV_SERVER_URL: "http://localhost:5173",
        },
      );

      assert.equal(environment.appUserModelId, "io.github.halc2.app.dev.local");
    }),
  );

  it.effect("resolves picker defaults without nullish sentinels", () =>
    Effect.gen(function* () {
      const environment = yield* makeEnvironment();

      assert.deepEqual(environment.resolvePickFolderDefaultPath(null), Option.none());
      assert.deepEqual(
        environment.resolvePickFolderDefaultPath({ initialPath: " " }),
        Option.none(),
      );
      assert.deepEqual(
        environment.resolvePickFolderDefaultPath({ initialPath: "~" }),
        Option.some("/Users/alice"),
      );
      assert.deepEqual(
        environment.resolvePickFolderDefaultPath({ initialPath: "~/project" }),
        Option.some("/Users/alice/project"),
      );
    }),
  );
});

import { OtlpHeadersFromString, OtlpProtocol } from "@hal-c2/shared/observability";
import * as Config from "effect/Config";
import * as ConfigProvider from "effect/ConfigProvider";
import * as Option from "effect/Option";

const trimNonEmptyOption = (value: string): Option.Option<string> => {
  const trimmed = value.trim();
  return trimmed.length > 0 ? Option.some(trimmed) : Option.none();
};

const trimmedString = (name: string) =>
  Config.String(name).pipe(Config.option, Config.map(Option.flatMap(trimNonEmptyOption)));

const optionalBoolean = (name: string) =>
  Config.Boolean(name).pipe(Config.option, Config.map(Option.getOrElse(() => false)));

const commaSeparatedStrings = (name: string) =>
  trimmedString(name).pipe(
    Config.map(
      Option.match({
        onNone: () => [],
        onSome: (value) =>
          value
            .split(",")
            .map((entry) => entry.trim())
            .filter((entry) => entry.length > 0),
      }),
    ),
  );

const compactEnv = (env: Readonly<Record<string, string | undefined>>): Record<string, string> =>
  Object.fromEntries(
    Object.entries(env).filter((entry): entry is [string, string] => entry[1] !== undefined),
  );

export const DesktopConfig = Config.all({
  appDataDirectory: trimmedString("APPDATA"),
  xdgConfigHome: trimmedString("XDG_CONFIG_HOME"),
  xdgDataHome: trimmedString("XDG_DATA_HOME"),
  xdgStateHome: trimmedString("XDG_STATE_HOME"),
  xdgCacheHome: trimmedString("XDG_CACHE_HOME"),
  xdgRuntimeDir: trimmedString("XDG_RUNTIME_DIR"),
  localAppDataDirectory: trimmedString("LOCALAPPDATA"),
  halC2Home: trimmedString("HAL_C2_HOME"),
  devServerUrl: Config.URL("VITE_DEV_SERVER_URL").pipe(Config.option),
  appUserModelIdOverride: trimmedString("HAL_C2_DESKTOP_APP_USER_MODEL_ID"),
  devRemoteHalC2ServerEntryPath: trimmedString("HAL_C2_DEV_REMOTE_HAL_C2_SERVER_ENTRY_PATH"),
  mcRelease: trimmedString("HAL_C2_DESKTOP_ELIXIR_RELEASE"),
  configuredBackendPort: Config.Port("HAL_C2_PORT").pipe(Config.option),
  commitHashOverride: trimmedString("HAL_C2_COMMIT_HASH"),
  desktopLanHostOverride: trimmedString("HAL_C2_DESKTOP_LAN_HOST"),
  desktopHttpsEndpointUrls: commaSeparatedStrings("HAL_C2_DESKTOP_HTTPS_ENDPOINTS"),
  otlpTracesUrl: trimmedString("HAL_C2_OTLP_TRACES_URL"),
  otlpMetricsUrl: trimmedString("HAL_C2_OTLP_METRICS_URL"),
  otlpLogsUrl: trimmedString("HAL_C2_OTLP_LOGS_URL"),
  otlpExportIntervalMs: Config.Int("HAL_C2_OTLP_EXPORT_INTERVAL_MS").pipe(
    Config.withDefault(10_000),
  ),
  otlpHeaders: Config.schema(OtlpHeadersFromString, "HAL_C2_OTLP_HEADERS").pipe(Config.option),
  otlpProtocol: Config.schema(OtlpProtocol, "HAL_C2_OTLP_PROTOCOL").pipe(
    Config.withDefault("http/json"),
  ),
  appImagePath: trimmedString("APPIMAGE"),
  disableAutoUpdate: optionalBoolean("HAL_C2_DISABLE_AUTO_UPDATE"),
  mockUpdates: optionalBoolean("HAL_C2_DESKTOP_MOCK_UPDATES"),
  mockUpdateServerPort: Config.Port("HAL_C2_DESKTOP_MOCK_UPDATE_SERVER_PORT").pipe(
    Config.withDefault(3000),
  ),
});

export const layerTest = (env: Readonly<Record<string, string | undefined>>) =>
  ConfigProvider.layer(ConfigProvider.fromEnv({ env: compactEnv(env) }));

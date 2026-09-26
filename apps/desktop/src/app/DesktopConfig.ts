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
  halc2Home: trimmedString("HALC2_HOME"),
  devServerUrl: Config.URL("VITE_DEV_SERVER_URL").pipe(Config.option),
  appUserModelIdOverride: trimmedString("HALC2_DESKTOP_APP_USER_MODEL_ID"),
  devRemoteHalC2ServerEntryPath: trimmedString("HALC2_DEV_REMOTE_HALC2_SERVER_ENTRY_PATH"),
  elixirNodeRelease: trimmedString("HALC2_DESKTOP_ELIXIR_RELEASE"),
  configuredBackendPort: Config.Port("HALC2_PORT").pipe(Config.option),
  commitHashOverride: trimmedString("HALC2_COMMIT_HASH"),
  desktopLanHostOverride: trimmedString("HALC2_DESKTOP_LAN_HOST"),
  desktopHttpsEndpointUrls: commaSeparatedStrings("HALC2_DESKTOP_HTTPS_ENDPOINTS"),
  otlpTracesUrl: trimmedString("HALC2_OTLP_TRACES_URL"),
  otlpMetricsUrl: trimmedString("HALC2_OTLP_METRICS_URL"),
  otlpLogsUrl: trimmedString("HALC2_OTLP_LOGS_URL"),
  otlpExportIntervalMs: Config.Int("HALC2_OTLP_EXPORT_INTERVAL_MS").pipe(
    Config.withDefault(10_000),
  ),
  otlpHeaders: Config.schema(OtlpHeadersFromString, "HALC2_OTLP_HEADERS").pipe(Config.option),
  otlpProtocol: Config.schema(OtlpProtocol, "HALC2_OTLP_PROTOCOL").pipe(
    Config.withDefault("http/json"),
  ),
  appImagePath: trimmedString("APPIMAGE"),
  disableAutoUpdate: optionalBoolean("HALC2_DISABLE_AUTO_UPDATE"),
  mockUpdates: optionalBoolean("HALC2_DESKTOP_MOCK_UPDATES"),
  mockUpdateServerPort: Config.Port("HALC2_DESKTOP_MOCK_UPDATE_SERVER_PORT").pipe(
    Config.withDefault(3000),
  ),
});

export const layerTest = (env: Readonly<Record<string, string | undefined>>) =>
  ConfigProvider.layer(ConfigProvider.fromEnv({ env: compactEnv(env) }));

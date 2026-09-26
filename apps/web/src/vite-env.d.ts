/// <reference types="vite-plus/client" />

import type { DesktopBridge } from "@hal-c2/contracts";
import type { HalC2Shell } from "@hal-c2/contracts/shell";
import type { ShellThemeBootstrap } from "./shell/shellThemeOverride";

interface ImportMetaEnv {
  readonly VITE_HTTP_URL: string;
  readonly VITE_WS_URL: string;
  readonly VITE_HOSTED_APP_URL: string;
  readonly VITE_HOSTED_APP_CHANNEL: string;
  readonly VITE_CLERK_PUBLISHABLE_KEY: string;
  readonly VITE_CLERK_JWT_TEMPLATE: string;
  readonly VITE_CLERK_CLI_OAUTH_CLIENT_ID: string;
  readonly VITE_RELAY_OTLP_TRACES_URL: string;
  readonly VITE_RELAY_OTLP_TRACES_DATASET: string;
  readonly VITE_RELAY_OTLP_TRACES_TOKEN: string;
  readonly APP_VERSION: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

declare global {
  interface Window {
    desktopBridge?: DesktopBridge;
    halC2Shell?: HalC2Shell;
    __halC2ShellTheme?: ShellThemeBootstrap;
    __halC2AppViewStorageId?: string;
  }
}

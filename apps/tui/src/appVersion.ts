/**
 * The HAL-C2 release this client is, which decides whether a server is behind it
 * (host/sections/updates.ts). `build.ts` bakes in the MC's release; the
 * environment variable names a different one (a local build against a nightly).
 */
declare const __HAL_C2_APP_VERSION__: string | undefined;

export function resolveAppVersion(
  env: Readonly<Record<string, string | undefined>>,
  bundled: string | undefined,
): string | null {
  return env.HAL_C2_TUI_APP_VERSION?.trim() || bundled?.trim() || null;
}

/** `undefined` when run from source, which has no bundle to stamp. */
export const bundledAppVersion: string | undefined =
  typeof __HAL_C2_APP_VERSION__ === "undefined" ? undefined : __HAL_C2_APP_VERSION__;

import { createDebugLogger } from "../../lib/debugLog";

/**
 * Debug logging for the mobile terminal pipeline. Prefix: `[hal-c2-terminal]`.
 *
 * Enabled when `__DEV__` is true, or set `globalThis.__HALC2_TERMINAL_DEBUG__`
 * (or the shared `globalThis.__HALC2_DEBUG__` filter) in a JS debugger / Metro
 * console to trace release/TestFlight builds.
 */
const logger = createDebugLogger("terminal", {
  enabledInDev: true,
  legacyGlobalFlag: "__HALC2_TERMINAL_DEBUG__",
});

export function isTerminalDebugEnabled(): boolean {
  return logger.isEnabled();
}

export function terminalDebugLog(message: string, data?: Record<string, unknown>): void {
  logger.log(message, data);
}

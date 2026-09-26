import * as NodeChildProcess from "node:child_process";

type TerminalEnvironment = Readonly<Record<string, string | undefined>>;

const KITTY_GRAPHICS_MARKERS = [
  "GHOSTTY_RESOURCES_DIR",
  "KITTY_WINDOW_ID",
  "KONSOLE_VERSION",
  "WEZTERM_PANE",
] as const;

const TERMINAL_NAME_KEYS = ["LC_TERMINAL", "TERM", "TERM_PROGRAM"] as const;
const KITTY_GRAPHICS_TERMINAL_NAME = /(?:^|[-_ ])(?:ghostty|kitty|konsole|wezterm)(?:$|[-_ ])/i;

function parseTmuxEnvironment(output: string): Record<string, string> {
  const parsed: Record<string, string> = {};
  for (const line of output.split("\n")) {
    const separator = line.indexOf("=");
    if (separator <= 0) continue;
    parsed[line.slice(0, separator)] = line.slice(separator + 1);
  }
  return parsed;
}

/** True only for terminals known to implement the Kitty graphics protocol. */
export function isKnownKittyGraphicsTerminal(
  environment: TerminalEnvironment,
  tmuxEnvironmentOutput = "",
): boolean {
  const environments = [environment, parseTmuxEnvironment(tmuxEnvironmentOutput)];
  return environments.some(
    (candidate) =>
      KITTY_GRAPHICS_MARKERS.some((key) => Boolean(candidate[key])) ||
      TERMINAL_NAME_KEYS.some((key) =>
        KITTY_GRAPHICS_TERMINAL_NAME.test(candidate[key]?.trim() ?? ""),
      ),
  );
}

/**
 * How inline images reach the terminal: written straight to it ("direct"),
 * wrapped in tmux passthrough to the terminal outside tmux ("tmux"), or not at
 * all (null) when the terminal is not one known to draw Kitty graphics.
 */
export type InlineImageTransport = "direct" | "tmux";

/**
 * The inline-image decision for a terminal environment. Inside tmux the pane
 * names tmux, not the terminal, so `readTmuxEnvironment` supplies tmux's global
 * environment, which keeps the client terminal's original TERM/TERM_PROGRAM.
 */
export function inlineImageTransport(
  environment: TerminalEnvironment,
  readTmuxEnvironment: () => string = () => "",
): InlineImageTransport | null {
  if (!environment.TMUX) return isKnownKittyGraphicsTerminal(environment) ? "direct" : null;
  return isKnownKittyGraphicsTerminal(environment, readTmuxEnvironment()) ? "tmux" : null;
}

/**
 * `inlineImageTransport` for this process: reads tmux's global environment
 * (a bounded local `tmux show-environment -g`) only when running inside tmux,
 * so Ghostty-over-SSH can opt into graphics passthrough without guessing.
 */
export function detectInlineImageTransport(
  environment: TerminalEnvironment = process.env,
): InlineImageTransport | null {
  return inlineImageTransport(environment, () => {
    const result = NodeChildProcess.spawnSync("tmux", ["show-environment", "-g"], {
      encoding: "utf8",
      timeout: 250,
      windowsHide: true,
    });
    return result.status === 0 ? (result.stdout ?? "") : "";
  });
}

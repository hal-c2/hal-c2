/** The languages whose code blocks a reply offers to run. */
const SHELL_LANGUAGES = /^(?:sh|bash|zsh|fish|shell|powershell|pwsh)$/;

/**
 * The command a reply's code block runs in the thread's terminal, or null when it
 * offers no run: only a closed shell block of one line, not still streaming, not
 * ending in a backslash. Control and invisible format characters (bidi overrides,
 * zero-width) could make the shown command differ from what the terminal receives,
 * so a block with any is not run. Ported from pingdotgg/t3code#13060.
 */
export function runnableShellCommand(
  block: { readonly source: string; readonly language: string; readonly closed: boolean },
  streaming: boolean,
): string | null {
  if (streaming || !block.closed || !SHELL_LANGUAGES.test(block.language)) return null;
  const command = block.source.trim();
  if (command.length === 0 || command.endsWith("\\")) return null;
  if (/[\p{Cc}\p{Cf}]/u.test(block.source)) return null;
  return command;
}

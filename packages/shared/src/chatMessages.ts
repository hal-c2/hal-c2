export const MAX_COLLAPSED_USER_MESSAGE_LINES = 8;
export const MAX_COLLAPSED_USER_MESSAGE_LENGTH = 600;

/**
 * What a message shows, for measuring it: a link or reference reads as its
 * label, not its (possibly long) destination. Link syntax inside a code span
 * shows as written, destination included, so it is measured in full.
 */
function shownText(text: string): string {
  return text.replace(
    /(?<ticks>`+)(?:[^`]|[^`][\s\S]*?[^`])\k<ticks>(?!`)|!?\[(?<label>[^\]\n]*)\]\((?:[^()\s]|\([^()\s]*\))+\)/g,
    (whole, _ticks: string | undefined, label: string | undefined) =>
      label === undefined ? whole : label,
  );
}

/** Keep long prompts from dominating the conversation timeline. */
export function shouldCollapseUserMessage(text: string): boolean {
  if (text.trim().length === 0) return false;
  return (
    shownText(text).length > MAX_COLLAPSED_USER_MESSAGE_LENGTH ||
    text.split("\n").length > MAX_COLLAPSED_USER_MESSAGE_LINES
  );
}

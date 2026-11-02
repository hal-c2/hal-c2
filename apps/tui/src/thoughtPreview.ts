/**
 * What finished reasoning is labelled by: its words alone, as the web's
 * remarkThoughtPreview reads them. Markup goes, a picture reads as its
 * description, a link as its text, HTML and link definitions as nothing, and
 * every run of whitespace is one space. Reasoning with no words reads
 * `fallback`.
 */
export function thoughtPreview(markdown: string, fallback: string): string {
  const words = markdown
    // Fenced code keeps its code, not its fences.
    .replace(/^ {0,3}(`{3,}|~{3,})[^\n]*$/gm, "")
    // Link definitions and HTML say nothing.
    .replace(/^ {0,3}\[[^\]\n]+\]:[^\n]*$/gm, "")
    .replace(/<[^>\n]+>/g, "")
    // A picture is its description; a link its text.
    .replace(/!\[([^\]\n]*)\]\([^)\n]*\)/g, "$1")
    .replace(/!\[([^\]\n]*)\]\[[^\]\n]*\]/g, "$1")
    .replace(/\[([^\]\n]*)\]\([^)\n]*\)/g, "$1")
    .replace(/\[([^\]\n]*)\]\[[^\]\n]*\]/g, "$1")
    // Block markers: headings, quotes, list bullets and numbers, rules, table pipes.
    .replace(/^ {0,3}#{1,6}[ \t]+/gm, "")
    .replace(/[ \t]+#+[ \t]*$/gm, "")
    .replace(/^ {0,3}(> ?)+/gm, "")
    .replace(/^[ \t]*([-*+]|\d+[.)])[ \t]+(\[[ xX]\][ \t]+)?/gm, "")
    .replace(/^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$/gm, "")
    .replace(/^[ \t]*\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/gm, "")
    .replace(/\|/g, " ")
    // Emphasis, strikethrough and code spans.
    .replace(/(\*\*|__|~~)(?=\S)([\s\S]*?\S)\1/g, "$2")
    .replace(/(\*|_)(?=\S)([^*_\n]*?\S)\1/g, "$2")
    .replace(/`+([^`\n]*)`+/g, "$1")
    .replace(/\\([\\`*_{}[\]()#+\-.!|~>])/g, "$1")
    .replace(/\s+/g, " ")
    .trim();
  return words || fallback;
}

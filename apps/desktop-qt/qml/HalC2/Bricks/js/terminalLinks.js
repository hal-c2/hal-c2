.pragma library

// Web addresses and file paths in terminal output, and the one under a cell of the Terminal.

const URL_PATTERN = /https?:\/\/[^\s"'`<>]+/gi;
const FILE_PATH_PATTERN = /(?:~\/|\.{1,2}\/|\/|[A-Za-z]:[\\/]|\\\\)[^\s"'`<>]+|[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)+(?::\d+){0,2}/g;
// Longer lines and addresses are not searched (the terminal client's limits).
const MAX_LINE = 64 * 1024;
const MAX_LINK = 4 * 1024;

function trimClosingDelimiters(value) {
    let output = value.replace(/[.,;!?]+$/, "");
    const trimUnbalanced = (open, close) => {
        while (output.endsWith(close)) {
            if (output.split(open).length >= output.split(close).length)
                return;
            output = output.slice(0, -1);
        }
    };
    trimUnbalanced("(", ")");
    trimUnbalanced("[", "]");
    trimUnbalanced("{", "}");
    return output;
}

function isUrl(value) {
    return /^https?:\/\//iu.test(value);
}

// [{kind: "url"|"path", text, start, end}] in order.
function extract(line) {
    const matches = [];
    const collect = (kind, pattern) => {
        // QML's engine has no String.matchAll.
        pattern.lastIndex = 0;
        for (let raw = pattern.exec(line); raw !== null; raw = pattern.exec(line)) {
            if (raw[0].length === 0) {
                pattern.lastIndex += 1;
                continue;
            }
            const text = trimClosingDelimiters(raw[0]);
            if (text.length === 0 || text.length > MAX_LINK || (kind === "path" && isUrl(text)))
                continue;
            const candidate = { kind: kind, text: text, start: raw.index, end: raw.index + text.length };
            if (!matches.some(other => candidate.start < other.end && other.start < candidate.end))
                matches.push(candidate);
        }
    };
    collect("url", URL_PATTERN);
    collect("path", FILE_PATH_PATTERN);
    return matches.sort((a, b) => a.start - b.start);
}

// The link at (row, column) of a terminal `columns` wide, where `text` is its
// scrollback and screen with soft wraps joined and `row` counts from the top
// of the scrollback. A line takes a row per `columns` characters, so a link
// that wraps is found from any of its rows. Null when there is none.
function linkAt(text, columns, row, column) {
    if (columns <= 0 || row < 0 || column < 0)
        return null;
    const lines = text.split("\n");
    let top = 0;
    for (const line of lines) {
        const rows = Math.max(1, Math.ceil(line.length / columns));
        if (row < top + rows) {
            if (line.length > MAX_LINE)
                return null;
            const at = (row - top) * columns + column;
            return extract(line).find(link => at >= link.start && at < link.end) ?? null;
        }
        top += rows;
    }
    return null;
}

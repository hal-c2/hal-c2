.pragma library

// Chat markdown for the Markdown brick: splits a reply into segments the brick
// draws with one item each. Consecutive prose (paragraphs, headings, lists,
// rules) is one "prose" segment of rich text, so a selection runs across it;
// fenced code, tables and top-level quotes are segments of their own. The
// reply is untrusted: every character of it is escaped, links keep only safe
// schemes, and images become links, so the rich text never loads anything.
//
// Prose HTML refers to classes (h1..h6, c for inline code, hr, and checked or
// unchecked task items) that the brick styles from the theme, so a theme
// change never re-parses a reply. Margins are the brick's.

var PARAGRAPH_MARGIN = 10.4;
var HEADING_TOP = 20;
var HEADING_BOTTOM = 8;
var LIST_GUTTER = 20;
var ITEM_GAP = 4;

// Outer-margin placeholders: a prose segment zeroes its first block's top and
// its last block's bottom margin, as `.chat-markdown > :first-child` does.
var TOP = "\u0001T\u0001";
var BOTTOM = "\u0001B\u0001";

var SAFE_SCHEMES = ["http", "https", "mailto", "file"];

// ---------------------------------------------------------------------------
// Escaping and links

function escapeHtml(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// The href a link may carry, or null when it must render as plain text: web
// and mail links, file URLs, and scheme-less paths or fragments (the thread
// opens those in the file panel). A one-letter "scheme" is a Windows drive.
function safeHref(url) {
    var href = (url || "").trim();
    if (href.length === 0 || /[\u0000-\u001f]/.test(href))
        return null;
    var scheme = /^([a-zA-Z][a-zA-Z0-9+.-]*):/.exec(href);
    if (!scheme || scheme[1].length === 1)
        return href;
    return SAFE_SCHEMES.indexOf(scheme[1].toLowerCase()) >= 0 ? href : null;
}

var ENTITIES = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: "\u00a0", copy: "\u00a9", reg: "\u00ae", trade: "\u2122", hellip: "\u2026", mdash: "\u2014", ndash: "\u2013", larr: "\u2190", rarr: "\u2192", times: "\u00d7", middot: "\u00b7", bull: "\u2022" };

function decodeEntity(entity) {
    if (entity[0] === "#") {
        var code = entity[1] === "x" || entity[1] === "X" ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
        return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : "\ufffd";
    }
    return ENTITIES.hasOwnProperty(entity) ? ENTITIES[entity] : null;
}

// ---------------------------------------------------------------------------
// Inline markdown to HTML

var PUNCTUATION = /[!-\/:-@\[-`{-~\u2000-\u206f\u2e00-\u2e7f\u3000-\u303f]/;

function isSpace(ch) {
    return ch === undefined || /\s/.test(ch);
}

function isPunct(ch) {
    return ch !== undefined && PUNCTUATION.test(ch);
}

// Bare web addresses in text become links, as GFM's autolink literals do.
function linkify(text, inLink) {
    if (inLink)
        return escapeHtml(text);
    var out = "";
    var last = 0;
    var re = /\b(?:https?:\/\/|www\.)[^\s<>"`]+/g;
    var match;
    while ((match = re.exec(text)) !== null) {
        var url = match[0];
        // Trailing punctuation ends the sentence, not the link; a closing
        // paren stays when the link opened one.
        for (;;) {
            var tail = url[url.length - 1];
            if (/[.,:;!?"'*_~]/.test(tail))
                url = url.slice(0, -1);
            else if (tail === ")" && url.split("(").length < url.split(")").length)
                url = url.slice(0, -1);
            else
                break;
        }
        var href = url.indexOf("www.") === 0 ? "http://" + url : url;
        out += escapeHtml(text.slice(last, match.index)) + "<a href=\"" + escapeHtml(href) + "\">" + escapeHtml(url) + "</a>";
        last = match.index + url.length;
        re.lastIndex = last;
    }
    return out + escapeHtml(text.slice(last));
}

function nodesHtml(nodes, inLink) {
    var out = "";
    for (var i = 0; i < nodes.length; ++i) {
        var node = nodes[i];
        if (node.t === "text")
            out += linkify(node.v, inLink);
        else if (node.t === "delim")
            out += escapeHtml(new Array(node.n + 1).join(node.ch));
        else if (node.t === "open")
            out += node.image ? "![" : "[";
        else
            out += node.v;
    }
    return out;
}

// CommonMark's emphasis pass over nodes[from..]: matched delimiter runs become
// <b>, <i> or <s> around what they enclose.
function processEmphasis(nodes, from, inLink) {
    for (var c = from; c < nodes.length; ++c) {
        var closer = nodes[c];
        if (closer.t !== "delim" || !closer.canClose)
            continue;
        for (var o = c - 1; o >= from; --o) {
            var opener = nodes[o];
            if (opener.t !== "delim" || opener.ch !== closer.ch || !opener.canOpen)
                continue;
            if (closer.ch === "~") {
                if (opener.n !== closer.n || opener.n > 2)
                    continue;
            } else if ((opener.canClose || closer.canOpen) && (opener.orig + closer.orig) % 3 === 0 && !(opener.orig % 3 === 0 && closer.orig % 3 === 0)) {
                continue;
            }
            var use = closer.ch === "~" ? opener.n : opener.n >= 2 && closer.n >= 2 ? 2 : 1;
            var tag = closer.ch === "~" ? "s" : use === 2 ? "b" : "i";
            var inner = nodesHtml(nodes.slice(o + 1, c), inLink);
            opener.n -= use;
            closer.n -= use;
            nodes.splice(o + 1, c - o - 1, { t: "html", v: "<" + tag + ">" + inner + "</" + tag + ">" });
            var at = o + 2;
            if (closer.n === 0)
                nodes.splice(at, 1);
            if (opener.n === 0) {
                nodes.splice(o, 1);
                --at;
            }
            // Look at what now sits at the closer's place (the closer itself
            // when it has characters left).
            c = at - 1;
            break;
        }
    }
}

// Reads a link's `(destination "title")` at src[i], or null.
function readInlineLink(src, i) {
    if (src[i] !== "(")
        return null;
    var j = i + 1;
    while (j < src.length && /[ \t\n]/.test(src[j]))
        ++j;
    var dest = "";
    if (src[j] === "<") {
        var close = src.indexOf(">", j);
        if (close < 0 || src.slice(j, close).indexOf("\n") >= 0)
            return null;
        dest = src.slice(j + 1, close);
        j = close + 1;
    } else {
        var depth = 0;
        var start = j;
        while (j < src.length && !/[\s\u0000-\u001f]/.test(src[j])) {
            if (src[j] === "\\" && j + 1 < src.length) {
                j += 2;
                continue;
            }
            if (src[j] === "(")
                ++depth;
            else if (src[j] === ")") {
                if (depth === 0)
                    break;
                --depth;
            }
            ++j;
        }
        dest = src.slice(start, j).replace(/\\([!-\/:-@\[-`{-~])/g, "$1");
    }
    while (j < src.length && /[ \t\n]/.test(src[j]))
        ++j;
    var quote = src[j];
    if (quote === "\"" || quote === "'" || quote === "(") {
        var end = src.indexOf(quote === "(" ? ")" : quote, j + 1);
        if (end < 0)
            return null;
        j = end + 1;
        while (j < src.length && /[ \t\n]/.test(src[j]))
            ++j;
    }
    if (src[j] !== ")")
        return null;
    return { href: dest, end: j + 1 };
}

function normalizeLabel(label) {
    return label.trim().replace(/\s+/g, " ").toLowerCase();
}

// Renders one paragraph's (or cell's, or heading's) inline markdown as HTML.
function renderInline(src, ctx, inLink) {
    var nodes = [];
    var text = "";
    var i = 0;
    function flush() {
        if (text.length > 0) {
            nodes.push({ t: "text", v: text });
            text = "";
        }
    }
    while (i < src.length) {
        var ch = src[i];
        if (ch === "\\") {
            var next = src[i + 1];
            if (next === "\n") {
                flush();
                nodes.push({ t: "html", v: "<br/>" });
                i += 2;
                continue;
            }
            if (next !== undefined && /[!-\/:-@\[-`{-~]/.test(next)) {
                text += next;
                i += 2;
                continue;
            }
            text += ch;
            ++i;
            continue;
        }
        if (ch === "`") {
            var run = 1;
            while (src[i + run] === "`")
                ++run;
            var search = i + run;
            var found = -1;
            while (search < src.length) {
                var at = src.indexOf("`", search);
                if (at < 0)
                    break;
                var len = 1;
                while (src[at + len] === "`")
                    ++len;
                if (len === run) {
                    found = at;
                    break;
                }
                search = at + len;
            }
            if (found < 0) {
                text += src.slice(i, i + run);
                i += run;
                continue;
            }
            var code = src.slice(i + run, found).replace(/\n/g, " ");
            if (code.length > 2 && code[0] === " " && code[code.length - 1] === " " && code.trim().length > 0)
                code = code.slice(1, -1);
            flush();
            nodes.push({ t: "html", v: codeSpan(code) });
            i = found + run;
            continue;
        }
        if (ch === "!" && src[i + 1] === "[") {
            flush();
            nodes.push({ t: "open", image: true, active: true, at: i + 2 });
            i += 2;
            continue;
        }
        if (ch === "[") {
            flush();
            nodes.push({ t: "open", image: false, active: true, at: i + 1 });
            ++i;
            continue;
        }
        if (ch === "]") {
            flush();
            var o = nodes.length - 1;
            while (o >= 0 && nodes[o].t !== "open")
                --o;
            if (o < 0 || !nodes[o].active) {
                if (o >= 0)
                    nodes.splice(o, 1, { t: "text", v: nodes[o].image ? "![" : "[" });
                text += "]";
                ++i;
                continue;
            }
            var opener = nodes[o];
            var label = src.slice(opener.at, i);
            var link = readInlineLink(src, i + 1);
            var end = link ? link.end : -1;
            var href = link ? link.href : null;
            if (!link) {
                var ref = /^\[([^\]]*)\]/.exec(src.slice(i + 1));
                var key = ref && ref[1].trim().length > 0 ? ref[1] : label;
                var name = normalizeLabel(key);
                if (ctx.used !== null)
                    ctx.used.add(name);
                var def = ctx.refs.get(name);
                if (def !== undefined) {
                    href = def;
                    end = ref ? i + 1 + ref[0].length : i + 1;
                }
            }
            if (href === null) {
                nodes.splice(o, 1, { t: "text", v: opener.image ? "![" : "[" });
                text += "]";
                ++i;
                continue;
            }
            processEmphasis(nodes, o + 1, true);
            var inner = nodesHtml(nodes.slice(o + 1), true);
            var safe = safeHref(href);
            var html;
            if (opener.image) {
                // Images never load: the alt text links to the source.
                var alt = inner.length > 0 ? inner : escapeHtml(href);
                html = safe !== null ? "<a href=\"" + escapeHtml(safe) + "\">" + alt + "</a>" : alt;
            } else {
                html = safe !== null ? "<a href=\"" + escapeHtml(safe) + "\">" + inner + "</a>" : inner;
                // No links inside links.
                for (var k = 0; k < o; ++k) {
                    if (nodes[k].t === "open" && !nodes[k].image)
                        nodes[k].active = false;
                }
            }
            nodes.splice(o, nodes.length - o, { t: "html", v: html });
            i = end;
            continue;
        }
        if (ch === "<") {
            var tail = src.slice(i);
            var auto = /^<([a-zA-Z][a-zA-Z0-9+.-]{1,31}:[^\s<>]*)>/.exec(tail);
            var mail = auto ? null : /^<([a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>/.exec(tail);
            var br = /^<br\s*\/?>/i.exec(tail);
            if (auto || mail) {
                var target = auto ? safeHref(auto[1]) : "mailto:" + mail[1];
                var shown = escapeHtml(auto ? auto[1] : mail[1]);
                flush();
                nodes.push({ t: "html", v: target !== null && !inLink ? "<a href=\"" + escapeHtml(target) + "\">" + shown + "</a>" : shown });
                i += (auto || mail)[0].length;
                continue;
            }
            if (br) {
                flush();
                nodes.push({ t: "html", v: "<br/>" });
                i += br[0].length;
                continue;
            }
            text += ch;
            ++i;
            continue;
        }
        if (ch === "*" || ch === "_" || ch === "~") {
            var n = 1;
            while (src[i + n] === ch)
                ++n;
            var before = i > 0 ? src[i - 1] : undefined;
            var after = src[i + n];
            var leftFlanking = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before));
            var rightFlanking = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after));
            var canOpen = leftFlanking;
            var canClose = rightFlanking;
            if (ch === "_") {
                canOpen = leftFlanking && (!rightFlanking || isPunct(before));
                canClose = rightFlanking && (!leftFlanking || isPunct(after));
            }
            flush();
            nodes.push({ t: "delim", ch: ch, n: n, orig: n, canOpen: canOpen, canClose: canClose });
            i += n;
            continue;
        }
        if (ch === "&") {
            var entity = /^&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});/.exec(src.slice(i));
            var decoded = entity ? decodeEntity(entity[1]) : null;
            if (decoded !== null) {
                text += decoded;
                i += entity[0].length;
                continue;
            }
            text += ch;
            ++i;
            continue;
        }
        if (ch === "\n") {
            var hard = /  +$/.test(text);
            text = text.replace(/[ \t]+$/, "");
            flush();
            nodes.push({ t: "html", v: hard || ctx.lineBreaks ? "<br/>" : "\n" });
            ++i;
            while (src[i] === " " || src[i] === "\t")
                ++i;
            continue;
        }
        text += ch;
        ++i;
    }
    flush();
    processEmphasis(nodes, 0, !!inLink);
    return nodesHtml(nodes, !!inLink);
}

// Inline code: a background span with a thin space of padding either side
// (plain spaces, so a copied selection carries no odd characters).
function codeSpan(code) {
    var pad = "<span style=\"font-size:9px;white-space:pre\"> </span>";
    return "<span class=\"c\" style=\"white-space:pre-wrap\">" + pad + escapeHtml(code) + pad + "</span>";
}

// The visible text of inline markdown, for CSV copies.
function inlineText(src, ctx) {
    return renderInline(src, ctx, true).replace(/<br\/>/g, " ").replace(/<[^>]*>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"").replace(/&amp;/g, "&");
}

// ---------------------------------------------------------------------------
// Blocks

var FENCE = /^( {0,3})(`{3,}|~{3,})(.*)$/;
var ATX = /^ {0,3}(#{1,6})(?:[ \t]+|$)(.*)$/;
var THEMATIC = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
var QUOTE = /^ {0,3}> ?/;
var LIST_ITEM = /^( {0,3})([-+*]|\d{1,9}[.)])([ \t]+|$)(.*)$/;
var SETEXT = /^ {0,3}(=+|-+)[ \t]*$/;
var TABLE_DELIMITER = /^ {0,3}\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$/;
var DEFINITION = /^ {0,3}\[([^\]]+)\]:[ \t]*<?([^\s>]+)>?(?:[ \t]+(?:"[^"]*"|'[^']*'|\([^)]*\)))?[ \t]*$/;

function isBlank(line) {
    return /^[ \t]*$/.test(line);
}

function expandTabs(line) {
    if (line.indexOf("\t") < 0)
        return line;
    var out = "";
    for (var i = 0; i < line.length; ++i) {
        if (line[i] === "\t")
            out += new Array(4 - (out.length % 4) + 1).join(" ");
        else
            out += line[i];
    }
    return out;
}

function splitRow(line) {
    var row = line.trim();
    if (row[0] === "|")
        row = row.slice(1);
    if (row[row.length - 1] === "|" && row[row.length - 2] !== "\\")
        row = row.slice(0, -1);
    var cells = [];
    var cell = "";
    for (var i = 0; i < row.length; ++i) {
        if (row[i] === "\\" && row[i + 1] === "|") {
            cell += "|";
            ++i;
        } else if (row[i] === "|") {
            cells.push(cell.trim());
            cell = "";
        } else {
            cell += row[i];
        }
    }
    cells.push(cell.trim());
    return cells;
}

function isTableStart(lines, i) {
    if (i + 1 >= lines.length || lines[i].indexOf("|") < 0 || !TABLE_DELIMITER.test(lines[i + 1]))
        return false;
    return splitRow(lines[i]).length === splitRow(lines[i + 1]).length;
}

// Whether a line opens a block that ends a paragraph.
function interrupts(lines, i) {
    var line = lines[i];
    if (FENCE.test(line) || ATX.test(line) || THEMATIC.test(line) || QUOTE.test(line) || isTableStart(lines, i))
        return true;
    var item = LIST_ITEM.exec(line);
    return !!item && item[4].trim().length > 0 && (!/\d/.test(item[2][0]) || parseInt(item[2], 10) === 1);
}

function fenceTitle(meta) {
    if (!meta)
        return "";
    var attr = /(?:^|\s)(?:title|file(?:name)?)=(?:"([^"]+)"|'([^']+)'|(\S+))/i.exec(meta);
    if (attr)
        return attr[1] || attr[2] || attr[3];
    var tokens = meta.split(/\s+/);
    for (var i = 0; i < tokens.length; ++i) {
        if (/^[\w@][\w@.\/-]*\.[A-Za-z0-9]+$/.test(tokens[i]))
            return tokens[i];
    }
    return "";
}

// Parses lines into block nodes: heading, hr, code, quote, list, table, para.
// Each carries `src`, its source text, which tells whether a block read again
// is the one read before.
function parseBlocks(lines, ctx) {
    var blocks = [];
    var i = 0;
    while (i < lines.length) {
        if (isBlank(lines[i])) {
            ++i;
            continue;
        }
        var next = parseBlock(lines, i, ctx);
        if (next.block !== null)
            blocks.push(next.block);
        i = next.end;
    }
    return blocks;
}

function ended(block, end, closed) {
    return { block: block, end: end, closed: closed };
}

// Parses the block that starts at lines[i], which is not blank: `block` is its
// node (null for link definitions alone) and `end` the first line it leaves.
// `closed` says the block ended itself, so no line after it had a say: a fence
// with its closing fence, a heading, a rule. Any other block ends because of
// what lines[end] is, and of lines[end + 1] too when lines[end] has a "|" and
// could head a table (`interrupts`); nothing reads further than that, which is
// what `settled` relies on.
function parseBlock(lines, i, ctx) {
    var line = lines[i];
    var start = i;
    var fence = FENCE.exec(line);
    if (fence && !(fence[2][0] === "`" && fence[3].indexOf("`") >= 0)) {
        var marker = fence[2];
        var indent = fence[1].length;
        var info = fence[3].trim();
        var body = [];
        var closed = false;
        ++i;
        while (i < lines.length) {
            var close = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(lines[i]);
            if (close && close[1][0] === marker[0] && close[1].length >= marker.length) {
                closed = true;
                ++i;
                break;
            }
            var content = lines[i];
            var strip = 0;
            while (strip < indent && content[strip] === " ")
                ++strip;
            body.push(content.slice(strip));
            ++i;
        }
        var space = info.search(/\s/);
        var language = (space < 0 ? info : info.slice(0, space)).replace(/^\{\.?|\}$/g, "");
        return ended({ type: "code", code: body.join("\n"), language: language === "gitignore" ? "ini" : language, title: fenceTitle(space < 0 ? "" : info.slice(space + 1).trim()), open: !closed, src: lines.slice(start, i).join("\n") }, i, closed);
    }
    var atx = ATX.exec(line);
    if (atx) {
        var heading = atx[2].replace(/[ \t]+#+[ \t]*$/, "").replace(/^#+[ \t]*$/, "").trim();
        return ended({ type: "heading", level: atx[1].length, text: heading, src: line }, i + 1, true);
    }
    if (THEMATIC.test(line))
        return ended({ type: "hr", src: line }, i + 1, true);
    if (QUOTE.test(line)) {
        var quoted = [];
        while (i < lines.length && !isBlank(lines[i])) {
            if (QUOTE.test(lines[i]))
                quoted.push(lines[i].replace(QUOTE, ""));
            else if (quoted.length > 0 && !isBlank(quoted[quoted.length - 1]) && !interrupts(lines, i))
                quoted.push(lines[i]);
            else
                break;
            ++i;
        }
        var alert = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*$/i.exec(quoted[0] || "");
        if (alert)
            quoted.shift();
        return ended({ type: "quote", alert: alert ? alert[1].toLowerCase() : "", text: quoted.join("\n"), src: lines.slice(start, i).join("\n") }, i, false);
    }
    if (LIST_ITEM.test(line)) {
        var list = parseList(lines, i, ctx);
        return ended(list.block, list.end, false);
    }
    if (isTableStart(lines, i)) {
        var header = splitRow(lines[i]);
        var align = splitRow(lines[i + 1]).map(function (cell) {
            var left = cell[0] === ":";
            var right = cell[cell.length - 1] === ":";
            return left && right ? "center" : right ? "right" : "left";
        });
        var rows = [];
        i += 2;
        while (i < lines.length && !isBlank(lines[i]) && !(FENCE.test(lines[i]) || ATX.test(lines[i]) || QUOTE.test(lines[i]) || THEMATIC.test(lines[i]))) {
            var cells = splitRow(lines[i]);
            while (cells.length < header.length)
                cells.push("");
            rows.push(cells.slice(0, header.length));
            ++i;
        }
        return ended({ type: "table", header: header, align: align, rows: rows, src: lines.slice(start, i).join("\n") }, i, false);
    }
    if (/^ {4}/.test(line)) {
        var indented = [];
        while (i < lines.length && (/^ {4}/.test(lines[i]) || isBlank(lines[i]))) {
            indented.push(lines[i].slice(4));
            ++i;
        }
        while (indented.length > 0 && isBlank(indented[indented.length - 1]))
            indented.pop();
        return ended({ type: "code", code: indented.join("\n"), language: "", title: "", open: false, src: lines.slice(start, i).join("\n") }, i, false);
    }
    // A paragraph: link definitions first, then lines until a blank line,
    // an interrupting block, or a setext underline.
    var para = [];
    while (i < lines.length && !isBlank(lines[i])) {
        if (para.length > 0) {
            var setext = SETEXT.exec(lines[i]);
            if (setext)
                return ended({ type: "heading", level: setext[1][0] === "=" ? 1 : 2, text: para.join("\n").trim(), src: lines.slice(start, i + 1).join("\n") }, i + 1, true);
            if (interrupts(lines, i))
                break;
        } else {
            var definition = DEFINITION.exec(lines[i]);
            if (definition) {
                var label = normalizeLabel(definition[1]);
                if (!ctx.refs.has(label)) {
                    ctx.refs.set(label, definition[2]);
                    if (ctx.defined !== null)
                        ctx.defined.push(label);
                }
                ++i;
                continue;
            }
        }
        para.push(lines[i].replace(/^[ \t]+/, ""));
        ++i;
    }
    if (para.length === 0)
        return ended(null, i, false);
    return ended({ type: "para", text: para.join("\n").replace(/[ \t]+$/, ""), src: lines.slice(start, i).join("\n") }, i, false);
}

// Parses a list starting at lines[i]: items of the same marker kind, each
// item's lines stripped of its content indent and parsed as blocks.
function parseList(lines, i, ctx) {
    var first = LIST_ITEM.exec(lines[i]);
    var ordered = /\d/.test(first[2][0]);
    var delimiter = first[2][first[2].length - 1];
    var start = ordered ? parseInt(first[2], 10) : 1;
    var items = [];
    var loose = false;
    var begin = i;
    var sawBlank = false;
    while (i < lines.length) {
        var item = LIST_ITEM.exec(lines[i]);
        if (!item || /\d/.test(item[2][0]) !== ordered || item[2][item[2].length - 1] !== delimiter || THEMATIC.test(lines[i]))
            break;
        if (sawBlank && items.length > 0)
            loose = true;
        var spaces = item[3].length;
        var contentIndent = item[1].length + item[2].length + (spaces > 4 || item[4].length === 0 ? 1 : spaces);
        var body = [item[4]];
        var fenced = FENCE.test(item[4]);
        ++i;
        sawBlank = false;
        var inner = false;
        while (i < lines.length) {
            var line = lines[i];
            if (isBlank(line)) {
                body.push("");
                sawBlank = true;
                ++i;
                continue;
            }
            var indent = /^ */.exec(line)[0].length;
            if (indent >= contentIndent) {
                if (sawBlank)
                    inner = true;
                body.push(line.slice(contentIndent));
                sawBlank = false;
                ++i;
                continue;
            }
            // A lazy continuation of the item's paragraph.
            if (!sawBlank && !fenced && !interrupts(lines, i) && !LIST_ITEM.test(line) && !isBlank(body[body.length - 1] || "")) {
                body.push(line);
                ++i;
                continue;
            }
            break;
        }
        while (body.length > 0 && isBlank(body[body.length - 1]))
            body.pop();
        var task = null;
        var taskMatch = /^\[([ xX])\](?:[ \t]+|$)/.exec(body[0] || "");
        if (taskMatch) {
            task = taskMatch[1] !== " ";
            body[0] = body[0].slice(taskMatch[0].length);
        }
        var children = parseBlocks(body, ctx);
        if (inner && children.length > 1)
            loose = true;
        items.push({ task: task, children: children });
    }
    // Trailing blank lines belong to what follows, not the list.
    var end = i;
    while (end > begin && isBlank(lines[end - 1]))
        --end;
    return { block: { type: "list", ordered: ordered, start: start, loose: loose, items: items, src: lines.slice(begin, end).join("\n") }, end: i };
}

// ---------------------------------------------------------------------------
// Flow: blocks to entries. An html entry is prose rich text (relative to its
// `indent`); code, table and quote entries become segments of their own.

// A block element whose outer margins a segment resolves later.
function element(tag, attrs, style, inner) {
    return "<" + tag + attrs + " style=\"" + style + "margin-top:" + TOP + "px;margin-bottom:" + BOTTOM + "px\">" + inner + "</" + tag + ">";
}

function listStyle(ordered, depth) {
    var styles = ordered ? ["decimal", "lower-alpha", "lower-roman"] : ["disc", "circle", "square"];
    return styles[Math.min(depth, 2)];
}

function htmlEntry(html, indent, top, bottom) {
    return { kind: "html", html: html, indent: indent, top: top, bottom: bottom };
}

function flowBlock(block, indent, ctx) {
    switch (block.type) {
    case "para":
        return [htmlEntry(element("p", "", "", renderInline(block.text, ctx)), indent, PARAGRAPH_MARGIN, PARAGRAPH_MARGIN)];
    case "heading":
        return [htmlEntry(element("p", " class=\"h" + block.level + "\"", "", renderInline(block.text, ctx)), indent, HEADING_TOP, HEADING_BOTTOM)];
    case "hr":
        return [htmlEntry("<hr class=\"hr\" style=\"margin-top:" + TOP + "px;margin-bottom:" + BOTTOM + "px\"/>", indent, 0, 0)];
    case "code":
        return [{ kind: "code", code: block.code, language: block.language, title: block.title, open: block.open, indent: indent, top: PARAGRAPH_MARGIN, bottom: PARAGRAPH_MARGIN }];
    case "table":
        return [tableEntry(block, indent, ctx)];
    case "quote":
        return [{ kind: "quote", payload: block.text, alert: block.alert, indent: indent, top: PARAGRAPH_MARGIN, bottom: PARAGRAPH_MARGIN }];
    case "list":
        return flowList(block, indent, ctx);
    }
    return [];
}

function tableEntry(block, indent, ctx) {
    var header = block.header.map(function (cell) { return renderInline(cell, ctx); });
    var rows = block.rows.map(function (row) {
        return row.map(function (cell) { return renderInline(cell, ctx); });
    });
    var escapeCell = function (cell) { return cell.replace(/\n+/g, " ").trim().replace(/\|/g, "\\|"); };
    var markdown = [block.header, block.align.map(function (a) { return a === "center" ? ":---:" : a === "right" ? "---:" : "---"; })].concat(block.rows).map(function (row, r) {
        return "| " + (r === 1 ? row : row.map(escapeCell)).join(" | ") + " |";
    }).join("\n");
    var csv = [block.header].concat(block.rows).map(function (row) {
        return row.map(function (cell) {
            var value = inlineText(cell, ctx).replace(/\s+/g, " ").trim();
            return /[",\n]/.test(value) ? "\"" + value.replace(/"/g, "\"\"") + "\"" : value;
        }).join(",");
    }).join("\n");
    return { kind: "table", payload: JSON.stringify({ header: header, align: block.align, rows: rows, markdown: markdown, csv: csv }), indent: indent, top: PARAGRAPH_MARGIN, bottom: PARAGRAPH_MARGIN };
}

// Resolves an entry's outer margins: its natural ones, or zero at a segment's
// edges.
function resolve(entry, first, last) {
    return entry.html.split(TOP).join(String(first ? 0 : entry.top)).split(BOTTOM).join(String(last ? 0 : entry.bottom));
}

// A list's entries. Items are prose until one holds code, a table or a quote;
// that entry splits the list, and what follows continues at the item's indent
// (later items numbered on).
function flowList(block, indent, ctx) {
    var ordered = block.ordered;
    var depth = ordered ? ctx.olDepth : ctx.ulDepth;
    var last = block.start + block.items.length - 1;
    var gutter = ordered ? Math.max(LIST_GUTTER, (Math.max(String(block.start).length, String(last).length) + 1) * 8) : LIST_GUTTER;
    if (ordered)
        ctx.olDepth++;
    else
        ctx.ulDepth++;
    var tag = ordered ? "ol" : "ul";
    var style = "-qt-list-indent:0;list-style-type:" + listStyle(ordered, depth) + ";margin-left:" + gutter + "px;";
    var entries = [];
    var open = null; // the list fragment being built
    var closeFragment = function () {
        if (open !== null) {
            entries.push(htmlEntry(element(tag, open.attrs, style, open.items), indent, open.top, PARAGRAPH_MARGIN));
            open = null;
        }
    };
    for (var n = 0; n < block.items.length; ++n) {
        var item = block.items[n];
        var number = block.start + n;
        if (open === null)
            open = { attrs: ordered && number !== 1 ? " start=\"" + number + "\"" : "", items: "", count: 0, top: n === 0 ? PARAGRAPH_MARGIN : ITEM_GAP };
        var content = "";
        var rest = [];
        for (var k = 0; k < item.children.length; ++k) {
            var child = item.children[k];
            var flowed = flowBlock(child, indent + gutter, ctx);
            for (var f = 0; f < flowed.length; ++f) {
                var entry = flowed[f];
                if (rest.length > 0 || entry.kind !== "html")
                    rest.push(entry);
                else if (!block.loose && child.type === "para")
                    content += entry.html.replace(/^<p style="[^"]*">/, "").replace(/<\/p>$/, ""); // tight: straight in the item
                else
                    content += resolve(entry, false, false);
            }
        }
        var task = item.task === null ? "" : item.task ? " class=\"checked\"" : " class=\"unchecked\"";
        open.items += "<li" + task + (open.count > 0 ? " style=\"margin-top:" + ITEM_GAP + "px\"" : "") + ">" + content + "</li>";
        open.count++;
        // A block that is not prose closes the list; the item's remaining
        // prose continues at its content indent, later items number on.
        if (rest.length > 0) {
            closeFragment();
            entries = entries.concat(rest);
        }
    }
    closeFragment();
    if (ordered)
        ctx.olDepth--;
    else
        ctx.ulDepth--;
    return entries;
}

// ---------------------------------------------------------------------------
// Segments

// Wraps a standalone entry at its indent (a list's `margin-left` is relative
// to the enclosing block, so a div carries the indent).
function standalone(entry, first, last) {
    var html = resolve(entry, first, last);
    return entry.indent > 0 ? "<div style=\"margin-left:" + entry.indent + "px\">" + html + "</div>" : html;
}

function segment(kind, fields) {
    return {
        kind: kind,
        html: fields.html || "",
        code: fields.code || "",
        language: fields.language || "",
        title: fields.title || "",
        open: !!fields.open,
        indent: fields.indent || 0,
        payload: fields.payload || "",
        alert: fields.alert || "",
        top: fields.top || 0,
        bottom: fields.bottom || 0,
        gap: 0,
    };
}

// Adds a segment under the last one of `out`: its `gap` is the larger of the
// two margins that meet, zero for the first.
function append(out, next) {
    next.gap = out.length === 0 ? 0 : Math.max(out[out.length - 1].bottom, next.top);
    out.push(next);
}

// Ends the run of prose entries `prose` as one segment of `out`.
function closeProse(out, prose) {
    if (prose.length === 0)
        return;
    var html = "";
    for (var p = 0; p < prose.length; ++p)
        html += standalone(prose[p], p === 0, p === prose.length - 1);
    append(out, segment("prose", { html: html, top: prose[0].top, bottom: prose[prose.length - 1].bottom }));
    prose.length = 0;
}

// Adds a top-level block's entries to `out`. Prose entries wait in `prose` for
// the prose that follows; while streaming, a block starts a segment of its own.
function fold(out, prose, entries, streaming) {
    if (streaming)
        closeProse(out, prose);
    for (var e = 0; e < entries.length; ++e) {
        var entry = entries[e];
        if (entry.kind === "html") {
            prose.push(entry);
        } else {
            closeProse(out, prose);
            append(out, segment(entry.kind, entry));
        }
    }
}

// What parsing and rendering read: `refs` maps a link definition's label to
// its address, `used` collects the labels a render looked up and `defined` the
// ones a parse defined, when someone asks.
function context(lineBreaks, refs) {
    return { refs: refs, lineBreaks: lineBreaks, olDepth: 0, ulDepth: 0, used: null, defined: null };
}

// ---------------------------------------------------------------------------
// Quotes of assistant replies (AssistantCitation in packages/contracts)

var CITATION_LINK = /\[Assistant quote\]\(((?:hal-c2|t3)-citation:\/\/v1\/[^\s)]+)\)/g;
var CITATION_CONTEXT = 32;
var CITATION_MAX = 8000;
var CITATION_ID = 512;
var CITATION_FIELDS = ["text", "start", "end", "prefix", "suffix", "comment"];

// The quote and comment a citation link carries, or null for a link that is
// not a whole AssistantCitation (parseAssistantCitationHref), which the MC
// leaves as written too.
function citation(href) {
    var query = href.indexOf("?");
    if (query < 0 || href.indexOf("#") >= 0)
        return null;
    var path = href.slice(href.indexOf("://v1/") + 6, query).split("/");
    if (path.length !== 3)
        return null;
    var fields = {};
    var pairs = href.slice(query + 1).split("&");
    try {
        for (var p = 0; p < path.length; ++p) {
            var id = decodeURIComponent(path[p]).trim();
            if (id.length === 0 || id.length > CITATION_ID)
                return null;
        }
        for (var i = 0; i < pairs.length; ++i) {
            var eq = pairs[i].indexOf("=");
            var key = decodeURIComponent((eq < 0 ? pairs[i] : pairs[i].slice(0, eq)).replace(/\+/g, " "));
            if (eq < 0 || CITATION_FIELDS.indexOf(key) < 0 || fields[key] !== undefined)
                return null;
            fields[key] = decodeURIComponent(pairs[i].slice(eq + 1).replace(/\+/g, " "));
        }
    } catch (e) {
        return null;
    }
    var digits = /^\d{1,16}$/;
    if (fields.text === undefined || fields.prefix === undefined || fields.suffix === undefined || !digits.test(fields.start ?? "") || !digits.test(fields.end ?? ""))
        return null;
    if (!Number.isSafeInteger(Number(fields.end)) || Number(fields.end) <= Number(fields.start) || fields.text.trim().length === 0 || fields.text.length > CITATION_MAX || (fields.comment ?? "").length > CITATION_MAX || fields.prefix.length > CITATION_CONTEXT || fields.suffix.length > CITATION_CONTEXT)
        return null;
    return fields;
}

function escapeMarkdown(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/[\\`*_[\]{}()#+.!|~-]/g, "\\$&");
}

// A message with its citation links written out: each quote in a block of
// its own, and the user's comment under it (renderAssistantCitationsAsText).
function withCitations(text) {
    if (text.indexOf("-citation://v1/") < 0)
        return text;
    return text.replace(CITATION_LINK, function (source, href) {
        var cited = citation(href);
        if (cited === null)
            return source;
        var quote = escapeMarkdown(cited.text).split("\n").map(function (line) {
            return "> " + line;
        }).join("\n");
        var comment = cited.comment !== undefined ? "Comment: " + escapeMarkdown(cited.comment) + "\n\n" : "";
        return "\n\n> Assistant quote:\n" + quote + "\n\n" + comment;
    });
}

// The selector an AssistantCitation saves for `text.slice(rawStart, rawEnd)`:
// the quote as selected, and its UTF-16 place and surroundings in the text
// with each whitespace run read as one space (createAssistantTextSelector).
function selector(text, rawStart, rawEnd) {
    var quote = text.slice(rawStart, rawEnd);
    if (quote.trim().length === 0)
        return null;
    var normalize = function (value) {
        return value.replace(/\s+/g, " ");
    };
    var splitsPair = function (value, offset) {
        var before = value.charCodeAt(offset - 1);
        var after = value.charCodeAt(offset);
        return before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff;
    };
    var normalized = normalize(text);
    var start = normalize(text.slice(0, rawStart)).length;
    // A selection starting inside a whitespace run includes its one space.
    if (rawStart > 0 && /\s/.test(text[rawStart - 1]) && /\s/.test(text[rawStart]))
        start -= 1;
    var end = normalize(text.slice(0, rawEnd)).length;
    var prefixStart = Math.max(0, start - CITATION_CONTEXT);
    var suffixEnd = Math.min(normalized.length, end + CITATION_CONTEXT);
    if (splitsPair(normalized, prefixStart))
        prefixStart += 1;
    if (splitsPair(normalized, suffixEnd))
        suffixEnd -= 1;
    return { text: quote, start: start, end: end, prefix: normalized.slice(prefixStart, start), suffix: normalized.slice(end, suffixEnd) };
}

// ---------------------------------------------------------------------------
// Reading a text into segments

// What reading has cost since `takeTally`: the characters and lines taken
// from texts, the top-level blocks parsed and the ones rendered. Tests hold
// the cost of a delta to the block that grows with it.
var tally = { chars: 0, lines: 0, blocks: 0, flowed: 0 };

function takeTally() {
    var taken = tally;
    tally = { chars: 0, lines: 0, blocks: 0, flowed: 0 };
    return taken;
}

// The segments of a whole text, read in one go.
function read(text, lineBreaks, streaming) {
    var ctx = context(lineBreaks, new Map());
    var lines = withCitations(text).replace(/\r\n?/g, "\n").split("\n").map(expandTabs);
    var blocks = parseBlocks(lines, ctx);
    tally.chars += text.length;
    tally.lines += lines.length;
    tally.blocks += blocks.length;
    tally.flowed += blocks.length;
    var out = [];
    var prose = [];
    for (var b = 0; b < blocks.length; ++b)
        fold(out, prose, flowBlock(blocks[b], 0, ctx), streaming);
    closeProse(out, prose);
    return out;
}

// Finished texts by their flags and text, for a brick that is made again when
// its row scrolls back into view. A text that grows is never kept here.
var cache = new Map();
var CACHE_LIMIT = 200;

function finished(text, lineBreaks) {
    var key = (lineBreaks ? "b" : "-") + text;
    var hit = cache.get(key);
    if (hit !== undefined) {
        cache.delete(key);
        cache.set(key, hit);
        return hit;
    }
    var result = read(text, lineBreaks, false);
    cache.set(key, result);
    if (cache.size > CACHE_LIMIT)
        cache.delete(cache.keys().next().value);
    return result;
}

// A text that grows is read from its tail. Its top-level blocks settle from
// the front: a settled block is one no later text can change, so its entries
// are kept and the text before `cut` is never read again. Every call reads
// the lines from `cut` on, renders the blocks among them that differ from the
// last call, and settles those that now can. The result is what `read` makes
// of the whole text.
//
// One thing reaches back over settled blocks: a link definition turns every
// earlier `[label]` into a link. Each block remembers the labels it looked up,
// and a definition that appears, changes or goes renders those blocks again.
function following(lineBreaks) {
    return {
        lineBreaks: lineBreaks,
        length: -1, // of the text as last read
        cut: 0, // where the first unsettled block starts in the text
        refs: new Map(), // every link definition
        loose: new Map(), // the ones unsettled blocks made
        blocks: [], // settled: { entries, labels, node } (the node only with labels)
        users: new Map(), // label -> the settled blocks that looked it up, by index
        tail: [], // unsettled, as last read: { src, entries, labels }
        streaming: null, // how the segments are folded
        segments: [],
        folded: 0, // settled blocks in `segments`
        settled: 0, // their segments
        prose: [], // their last prose entries, which the next block may join
    };
}

// The lines of `raw`, the text from offset `base` on, as `read` splits them:
// `starts` has each line's offset in the text, or -1 for a line a quote link
// wrote out. Returns how many of them later text cannot change: all but the
// last, which more text lengthens. (After a carriage return the text ends on,
// the last line's offset may be the line feed of a CRLF; a tail read from
// there starts with a blank line, which changes nothing.)
function readLines(raw, base, lines, starts) {
    var breaks = /\r\n?|\n/g;
    var from = 0;
    var fixed = 0;
    var bare = false; // the line before ended on a carriage return alone
    for (;;) {
        var found = breaks.exec(raw);
        var line = raw.slice(from, found === null ? raw.length : found.index);
        var cited = withCitations(line);
        if (cited === line) {
            lines.push(expandTabs(line));
            starts.push(base + from);
        } else {
            var written = cited.replace(/\r\n?/g, "\n").split("\n");
            // That carriage return and the line feed a quote link starts
            // with are one line break to `read`.
            if (bare && cited[0] === "\n")
                written.shift();
            for (var w = 0; w < written.length; ++w) {
                lines.push(expandTabs(written[w]));
                starts.push(w === 0 ? base + from : -1);
            }
        }
        if (found === null)
            return fixed;
        from = found.index + found[0].length;
        fixed = lines.length;
        bare = found[0] === "\r";
    }
}

// Whether no later text can change a block parsed from `lines`, of which the
// first `fixed` cannot change: every line `parseBlock` read to make it is one
// of those.
function settled(lines, fixed, parsed) {
    var end = parsed.end;
    if (parsed.closed)
        return end <= fixed;
    return end < fixed && (lines[end].indexOf("|") < 0 || end + 1 < fixed);
}

function uses(labels, changed) {
    if (labels === null || changed.size === 0)
        return false;
    var found = false;
    labels.forEach(function (label) {
        found = found || changed.has(label);
    });
    return found;
}

// Renders a top-level block into `into`, noting the labels it looked up.
function flow(into, block, ctx) {
    ctx.used = new Set();
    into.entries = flowBlock(block, 0, ctx);
    into.labels = ctx.used.size > 0 ? ctx.used : null;
    ctx.used = null;
    ++tally.flowed;
}

function claim(users, labels, index) {
    labels.forEach(function (label) {
        if (!users.has(label))
            users.set(label, new Set());
        users.get(label).add(index);
    });
}

// Reads `text` from `live.cut` on. Returns whether settled blocks were
// rendered again.
function readTail(live, text) {
    var lines = [];
    var starts = [];
    var raw = text.slice(live.cut);
    var fixed = readLines(raw, live.cut, lines, starts);
    var refs = live.refs;
    var before = live.loose;
    before.forEach(function (url, label) {
        refs.delete(label);
    });
    var ctx = context(live.lineBreaks, refs);
    var parsed = [];
    var i = 0;
    while (i < lines.length) {
        if (isBlank(lines[i])) {
            ++i;
            continue;
        }
        ctx.defined = [];
        var next = parseBlock(lines, i, ctx);
        next.start = i;
        next.defined = ctx.defined;
        parsed.push(next);
        i = next.end;
    }
    ctx.defined = null;
    tally.chars += raw.length;
    tally.lines += lines.length;
    tally.blocks += parsed.length;

    // The labels defined otherwise than last time, and the settled blocks
    // that looked them up.
    var changed = new Set();
    before.forEach(function (url, label) {
        if (refs.get(label) !== url)
            changed.add(label);
    });
    var c;
    for (c = 0; c < parsed.length; ++c) {
        parsed[c].defined.forEach(function (label) {
            if (before.get(label) !== refs.get(label))
                changed.add(label);
        });
    }
    var stale = new Set();
    changed.forEach(function (label) {
        var users = live.users.get(label);
        if (users !== undefined)
            users.forEach(function (index) {
                stale.add(index);
            });
    });
    stale.forEach(function (index) {
        var drawn = live.blocks[index];
        flow(drawn, drawn.node, ctx);
        if (drawn.labels !== null)
            claim(live.users, drawn.labels, index);
    });

    // An unsettled block that reads as it did keeps its entries.
    for (c = 0; c < parsed.length; ++c) {
        var kept = live.tail[c];
        next = parsed[c];
        if (next.block === null) {
            next.entries = [];
            next.labels = null;
        } else if (kept !== undefined && kept.src === next.block.src && !uses(kept.labels, changed)) {
            next.entries = kept.entries;
            next.labels = kept.labels;
        } else {
            flow(next, next.block, ctx);
        }
    }

    // Blocks settle from the front, as far as the next one starts on a line
    // of the text itself.
    var count = 0;
    while (count < parsed.length && settled(lines, fixed, parsed[count]))
        ++count;
    var cut = -1;
    for (; count > 0; --count) {
        cut = starts[count < parsed.length ? parsed[count].start : fixed];
        if (cut >= 0)
            break;
    }
    if (count > 0)
        live.cut = cut;
    live.tail = [];
    live.loose = new Map();
    for (c = 0; c < parsed.length; ++c) {
        next = parsed[c];
        if (c >= count) {
            next.defined.forEach(function (label) {
                live.loose.set(label, refs.get(label));
            });
            live.tail.push({ src: next.block !== null ? next.block.src : null, entries: next.entries, labels: next.labels });
        } else if (next.block !== null) {
            if (next.labels !== null)
                claim(live.users, next.labels, live.blocks.length);
            live.blocks.push({ entries: next.entries, labels: next.labels, node: next.labels !== null ? next.block : null });
        }
    }
    return stale.size > 0;
}

// The segments of the text `state.live` follows, which has grown to `text` or
// is to be folded another way. `state.stable` says how many of them, from the
// first, are the ones the last call returned.
function advance(state, text, streaming) {
    var live = state.live;
    var refold = live.streaming !== streaming;
    var out = live.segments;
    if (text.length !== live.length) {
        refold = readTail(live, text) || refold;
        live.length = text.length;
    } else if (!refold) {
        state.stable = out.length;
        return out;
    }
    if (refold) {
        live.streaming = streaming;
        live.folded = 0;
        live.settled = 0;
        live.prose.length = 0;
    }
    out.length = live.settled;
    state.stable = live.settled;
    for (; live.folded < live.blocks.length; ++live.folded)
        fold(out, live.prose, live.blocks[live.folded].entries, streaming);
    // The next block starts a segment while streaming, so settled prose ends
    // here; otherwise it stays open for the prose that follows.
    if (streaming)
        closeProse(out, live.prose);
    live.settled = out.length;
    var prose = live.prose.slice();
    for (var t = 0; t < live.tail.length; ++t)
        fold(out, prose, live.tail[t].entries, streaming);
    closeProse(out, prose);
    return out;
}

// What a brick keeps between calls of `segments`, so that a text which grows
// is read from where it changed: the text it last gave, what `following` it
// has made of it, and the finished segments it last got.
function state() {
    return { text: null, live: null, kept: null, stable: 0 };
}

// The segments of a reply, each { kind, html, code, language, title, open,
// indent, gap, payload, alert }: `gap` is the space above it (the larger of the
// two margins that meet, zero for the first). While streaming, every top-level
// block is a segment of its own, so a delta re-lays out only the last block and
// a new block never re-renders the ones before it; the finished reply merges
// its prose so a selection can run across it.
//
// With a `state`, a text that streams, or that has grown since the last call,
// costs what its unsettled tail costs and not what the text does. The array
// returned is then the state's own and changes with the next call; its first
// `state.stable` segments are the ones the last call returned.
function segments(text, options, state) {
    var opts = options || {};
    var lineBreaks = !!opts.lineBreaks;
    var streaming = !!opts.streaming;
    if (!state)
        return streaming ? read(text, lineBreaks, true) : finished(text, lineBreaks);
    var before = state.text;
    var grown = before !== null && text.length >= before.length && text.startsWith(before);
    state.text = text;
    if (state.live !== null && !(grown && state.live.lineBreaks === lineBreaks))
        state.live = null;
    // A text is followed while it streams, and once it has grown.
    if (state.live === null && (streaming || (grown && before.length > 0 && text.length > before.length)))
        state.live = following(lineBreaks);
    try {
        if (state.live === null) {
            var result = finished(text, lineBreaks);
            state.stable = result === state.kept ? result.length : 0;
            state.kept = result;
            return result;
        }
        state.kept = null;
        return advance(state, text, streaming);
    } catch (error) {
        // The brick shows the last segments still, and nothing here matches
        // them any more: the next call starts over.
        state.text = null;
        state.live = null;
        state.kept = null;
        throw error;
    }
}

// ---------------------------------------------------------------------------
// Rendering helpers for the brick

// The stylesheet prose and table cells share, from the theme: link colour,
// heading colour, muted text for h6, the
// inline code fill and the rule colour.
function styleHead(theme) {
    var heading = "font-weight:600;color:" + theme.heading + ";";
    return "<style>"
        + "p,li{line-height:23px;-qt-line-height-type:minimum}"
        + "a{color:" + theme.link + ";text-decoration:none}"
        + ".h1{" + heading + "font-size:20px;line-height:26px}"
        + ".h2{" + heading + "font-size:18px;line-height:23.4px}"
        + ".h3{" + heading + "font-size:16px;line-height:20.8px}"
        + ".h4,.h5{" + heading + "font-size:14px;line-height:18.2px}"
        + ".h6{font-weight:600;color:" + theme.muted + ";font-size:14px;line-height:18.2px}"
        + ".c{background-color:" + theme.codeFill + ";color:" + theme.heading + ";font-size:12px;font-family:" + theme.mono + "}"
        + ".hr{background-color:" + theme.rule + "}"
        + "</style>";
}

// A code block's text as rich text: escaped, spaces kept, one line height
// for every line (leading-snug).
function codeHtml(code, lineHeight) {
    return "<p style=\"margin:0;white-space:pre-wrap;line-height:" + lineHeight + "px;-qt-line-height-type:minimum\">"
        + escapeHtml(code).replace(/\n/g, "<br/>") + "</p>";
}

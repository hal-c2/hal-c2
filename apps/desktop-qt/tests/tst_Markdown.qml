import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"
import "../qml/HalC2/Bricks/js/markdown.js" as Md

// The Markdown brick: the web's chat markdown in native segments
// (features/timeline/markdown.feature).
Item {
    id: root
    width: 600
    height: 800

    Component {
        id: markdownComponent
        Markdown {
            width: 560
        }
    }

    // Reads the clipboard back through a TextEdit.
    TextEdit {
        id: pasteTarget
        visible: false
        textFormat: TextEdit.PlainText
    }

    SignalSpy {
        id: linkSpy
        signalName: "linkActivated"
    }

    SignalSpy {
        id: citeSpy
        signalName: "cited"
    }

    TestCase {
        name: "Markdown"
        when: windowShown

        function make(text, props) {
            const md = createTemporaryObject(markdownComponent, root, Object.assign({ text: text }, props ?? {}));
            verify(md);
            return md;
        }

        function clipboardText() {
            pasteTarget.text = "";
            pasteTarget.paste();
            return pasteTarget.text;
        }

        function segmentsOf(md) {
            const out = [];
            const walk = item => {
                for (let i = 0; i < item.children.length; ++i) {
                    const child = item.children[i];
                    if (child.objectName === "markdownSegment")
                        out.push(child);
                    else
                        walk(child);
                }
            };
            walk(md);
            return out;
        }

        function prose(segment) {
            return findChild(segment, "markdownProse");
        }

        function plain(edit) {
            return edit.getText(0, edit.length);
        }

        function test_blocksBecomeSegments() {
            const md = make("# Title\n\nSome *text* and `code`.\n\n- one\n- two\n\n```ts\nconst a = 1;\n```\n\n| A | B |\n|---|--:|\n| 1 | 2 |\n\n> quoted\n\nAfter.");
            const kinds = segmentsOf(md).map(s => s.kind);
            compare(kinds, ["prose", "code", "table", "quote", "prose"]);
            const first = prose(segmentsOf(md)[0]);
            verify(plain(first).indexOf("Title") >= 0);
            verify(plain(first).indexOf("two") >= 0);
            compare(findChild(md, "codeLabel").text, "ts");
            verify(md.implicitHeight > 0);
        }

        function test_linkActivates() {
            const md = make("See the [pricing docs](https://example.com/docs/pricing) now.");
            linkSpy.target = md;
            linkSpy.clear();
            const edit = prose(segmentsOf(md)[0]);
            const at = plain(edit).indexOf("pricing");
            const rect = edit.positionToRectangle(at + 2);
            compare(edit.linkAt(rect.x + 1, rect.y + rect.height / 2), "https://example.com/docs/pricing");
            mouseClick(edit, rect.x + 1, rect.y + rect.height / 2);
            compare(linkSpy.count, 1);
            compare(linkSpy.signalArguments[0][0], "https://example.com/docs/pricing");
        }

        function test_codeCopiesItsSource() {
            const source = "const a = 1 < 2;\n  indented();";
            const md = make("```js\n" + source + "\n```");
            const button = findChild(md, "copyCode");
            mouseClick(button);
            compare(clipboardText(), source);
            compare(button.iconName, "check");
            tryCompare(button, "iconName", "copy", 3000);
        }

        function test_wrapToggleSwitchesLineWrap() {
            const md = make("```\n" + "word ".repeat(60) + "\n```");
            const toggle = findChild(md, "wrapCode");
            const code = findChild(md, "codeText");
            const block = findChild(md, "markdownCode");
            verify(toggle.checked, "wraps by default, as the wordWrap setting does");
            compare(code.wrapMode, TextEdit.WrapAtWordBoundaryOrAnywhere);
            const wrappedHeight = code.height;
            mouseClick(toggle);
            verify(!toggle.checked);
            compare(code.wrapMode, TextEdit.NoWrap);
            verify(code.width > block.width, "an unwrapped line scrolls sideways");
            verify(code.height < wrappedHeight);
            mouseClick(toggle);
            compare(code.wrapMode, TextEdit.WrapAtWordBoundaryOrAnywhere);
        }

        // A table that grows as the reply streams makes cells for its new
        // row only.
        function test_growingTableKeepsTheRowsItHas() {
            const head = "| Region | Rate |\n|---|---:|\n| North | 21% |\n";
            const md = make(head + "| South | 9", { streaming: true });
            const cells = () => {
                const found = [];
                const walk = item => {
                    if (item.objectName === "tableCell")
                        found.push(item);
                    for (let i = 0; i < item.children.length; ++i)
                        walk(item.children[i]);
                };
                walk(md);
                return found;
            };
            tryVerify(() => cells().length === 6);
            const before = cells();
            md.text = head + "| South | 9% |\n| West | 1";
            tryVerify(() => cells().length === 8);
            const after = cells();
            for (let i = 0; i < 6; ++i)
                verify(after[i] === before[i], "cell " + i + " is the one that was there");
            verify(after[5].text.indexOf("9%") >= 0, "the row that grew shows its new text");
        }

        function test_tableCopiesAsMarkdownAndCsv() {
            const md = make("| Region | Rate |\n|---|---:|\n| EU, north | 21% |\n| a\\|b | \"q\" |");
            const table = findChild(md, "markdownTable");
            table.copy("markdown");
            compare(clipboardText(), "| Region | Rate |\n| --- | ---: |\n| EU, north | 21% |\n| a\\|b | \"q\" |");
            table.copy("csv");
            compare(clipboardText(), "Region,Rate\n\"EU, north\",21%\na|b,\"\"\"q\"\"\"");
            const expand = findChild(md, "expandTable");
            verify(expand.checked);
            mouseClick(expand);
            verify(!table.expanded);
        }

        // A reply streams in: blocks already shown keep their items and their
        // text, only the last block changes, and a new block adds a segment.
        function test_streamingKeepsEarlierBlocks() {
            const md = make("First paragraph.\n\nSecond", { streaming: true });
            let segments = segmentsOf(md);
            compare(segments.length, 2);
            const firstItem = segments[0];
            const firstEdit = prose(firstItem);
            const firstText = firstEdit.text;
            let rewrites = 0;
            firstEdit.textChanged.connect(() => ++rewrites);

            md.text = "First paragraph.\n\nSecond grows";
            md.text = "First paragraph.\n\nSecond grows longer.\n\n```py\nprint(1)";
            md.text = "First paragraph.\n\nSecond grows longer.\n\n```py\nprint(1)\nprint(2)";
            segments = segmentsOf(md);
            compare(segments.length, 3);
            verify(segments[0] === firstItem, "the first block keeps its item");
            compare(prose(segments[0]).text, firstText);
            compare(rewrites, 0);
            compare(segments[2].kind, "code");
            verify(segments[2].open, "an unterminated fence is a code block in progress");
            const code = findChild(segments[2], "codeText");
            const codeItem = code;
            md.text += "\n```";
            compare(findChild(segmentsOf(md)[2], "codeText"), codeItem, "closing the fence keeps the block");
            verify(!segmentsOf(md)[2].open);

            // Finished, the prose merges so a selection runs across it.
            md.streaming = false;
            compare(segmentsOf(md).map(s => s.kind), ["prose", "code"]);
            verify(plain(prose(segmentsOf(md)[0])).indexOf("Second grows longer.") >= 0);
        }

        function test_untrustedHtmlStaysText() {
            const md = make("<script>alert(1)</script> <img src=\"https://example.com/x.png\"> <b>bold?</b>\n\n[click](javascript:alert(1)) ![pic](https://example.com/y.png)");
            const edit = prose(segmentsOf(md)[0]);
            const text = plain(edit);
            verify(text.indexOf("<script>alert(1)</script>") >= 0, text);
            verify(text.indexOf("<b>bold?</b>") >= 0, text);
            verify(edit.text.indexOf("<img") < 0, "no image is ever loaded");
            verify(edit.text.indexOf("javascript:") < 0, "unsafe links render as plain text");
            // An image is a link to its source, never fetched.
            const at = text.indexOf("pic");
            const rect = edit.positionToRectangle(at + 1);
            compare(edit.linkAt(rect.x + 1, rect.y + rect.height / 2), "https://example.com/y.png");
        }

        function test_lineBreaksKeepUserNewlines() {
            const md = make("one\ntwo", { lineBreaks: true });
            verify(prose(segmentsOf(md)[0]).lineCount >= 2);
            const joined = make("one\ntwo");
            compare(prose(segmentsOf(joined)[0]).lineCount, 1);
        }

        // Dragging over words and pressing the copy key copies them.
        function test_selectionCopiesWithTheCopyKey() {
            const md = make("Refunds reuse the old rate.");
            const edit = prose(segmentsOf(md)[0]);
            const from = edit.positionToRectangle(0);
            const to = edit.positionToRectangle(7);
            mouseDrag(edit, from.x, from.y + from.height / 2, to.x - from.x, 0);
            compare(edit.selectedText, "Refunds");
            keySequence(StandardKey.Copy);
            compare(clipboardText(), "Refunds");
        }

        function test_citeQuotesTheSelectionInItsReply() {
            const md = make("# Rates\n\nRefunds reuse the old rate.\n\n```\ncode\n```\n\nAfter the code.", { citable: true });
            citeSpy.target = md;
            citeSpy.clear();
            const button = findChild(md, "citeSelection");
            verify(!button.visible, "nothing is selected yet");
            const edit = prose(segmentsOf(md)[2]);
            edit.forceActiveFocus();
            edit.select(0, 5);
            verify(button.visible, "a selection offers Cite");
            verify(button.y >= 0 && button.y + button.height <= md.height, "inside the reply");
            mouseClick(button);
            compare(citeSpy.count, 1);
            const selector = citeSpy.signalArguments[0][0];
            compare(selector.text, "After");
            compare(selector.suffix, " the code.");
            verify(selector.prefix.endsWith("code "), "the text before it is the reply's: " + selector.prefix);
            compare(selector.end - selector.start, 5);
            compare(edit.selectedText, "", "the selection is let go");
            verify(!button.visible);
        }

        // A one-line reply has no line above for Cite to sit on.
        function test_citeSitsUnderAOneLineReply() {
            const md = make("Refunds reuse the old rate.", { citable: true });
            const edit = prose(segmentsOf(md)[0]);
            edit.forceActiveFocus();
            edit.select(0, 7);
            const button = findChild(md, "citeSelection");
            verify(button.visible);
            verify(button.y >= edit.height, "under the line: " + button.y);
        }

        // A quote's text is cited through the reply it sits in.
        function test_citeQuotesASelectionInsideABlockQuote() {
            const md = make("Before.\n\n> Refunds reuse the old rate.", { citable: true });
            citeSpy.target = md;
            citeSpy.clear();
            const edit = findChild(findChild(md, "markdownQuote"), "markdownProse");
            edit.forceActiveFocus();
            edit.select(0, 7);
            compare(md.selection, edit, "the reply holds the selection");
            const button = findChild(md, "citeSelection");
            verify(button.visible);
            mouseClick(button);
            compare(citeSpy.count, 1);
            compare(citeSpy.signalArguments[0][0].text, "Refunds");
            compare(md.selection, null);
        }

        function test_plainRepliesOfferNoCite() {
            const md = make("Refunds reuse the old rate.");
            const edit = prose(segmentsOf(md)[0]);
            edit.forceActiveFocus();
            edit.select(0, 7);
            verify(!findChild(md, "citeSelection").visible);
        }

        // A sent quote reads as a quote with the user's comment under it.
        // An escaped key (`%63omment`) is the key it spells, as the MC reads it.
        function test_citationLinkReadsAsAQuote() {
            const md = make("Why? [Assistant quote](hal-c2-citation://v1/env/thread/msg?text=cache+%5Bkeys%5D&start=0&end=12&prefix=&suffix=&%63omment=too+slow%3F) Thanks.", { lineBreaks: true });
            const segments = segmentsOf(md);
            compare(segments.map(s => s.kind), ["prose", "quote", "prose"]);
            const quoted = findChild(segments[1], "markdownProse");
            verify(plain(quoted).indexOf("Assistant quote:") >= 0);
            verify(plain(quoted).indexOf("cache [keys]") >= 0, plain(quoted));
            verify(plain(prose(segments[2])).indexOf("Comment: too slow?") >= 0, plain(prose(segments[2])));
        }

        // What the MC does not read as a quote is not shown as one.
        function test_malformedCitationLinkStaysALink() {
            const links = ["hal-c2-citation://v1/env/thread?text=a&start=0&end=1&prefix=&suffix=", "hal-c2-citation://v1/env/thread/msg?text=a&start=1&end=1&prefix=&suffix=", "hal-c2-citation://v1/env/thread/msg?text=a&start=0&end=1&prefix=&suffix=&extra=1", "hal-c2-citation://v1/env/thread/msg?text=a", "hal-c2-citation://v1/%ZZ/thread/msg?text=a&start=0&end=1&prefix=&suffix=", "hal-c2-citation://v1/env/thread/%20?text=a&start=0&end=1&prefix=&suffix=", "hal-c2-citation://v1/env/thread/msg?text=%FF&start=0&end=1&prefix=&suffix=", "hal-c2-citation://v1/env/thread/msg?text=a&start=0&end=9007199254740992&prefix=&suffix="];
            for (const link of links) {
                const md = make("See [Assistant quote](" + link + ")");
                compare(segmentsOf(md).map(s => s.kind), ["prose"], link);
            }
        }

        function test_alertTitlesItsKind() {
            const md = make("> [!WARNING]\n> Refunds reuse the old rate.");
            const quote = findChild(md, "markdownQuote");
            verify(quote);
            compare(findChild(quote, "alertTitle").text, "Warning");
        }

        // A quote link as the composer sends it: a quote of two lines and a comment.
        readonly property string quoteLink: "[Assistant quote](hal-c2-citation://v1/env/thread/msg?text=cache+%5Bkeys%5D%0Asecond+line&start=0&end=12&prefix=&suffix=&comment=too+slow%3F)"

        // Definitions that arrive after the blocks that use them.
        readonly property string lateDefinitions: "See [the docs][ref] and [ref] here.\n\n- A list item with [ref]\n- [x] and a task with [other][]\n\n| Cell [ref] | B |\n|---|---|\n| [other] | 2 |\n\n> A quote with [ref] of its own.\n\n## Heading [ref]\n\nPlain paragraph.\n\n[ref]: https://example.com/reference/that/arrives/late\n[other]: <https://example.com/other>\n\nAfter [ref].\n\n[ref]: https://example.com/too-late\n\n- [third] in a list\n\n  [third]: /defined/inside/the/item\n"
        // Lists in lists, and other blocks in items.
        readonly property string nestedBlocks: "- level one\n  - level two\n    - level three\n      1. ordered\n         a. not nested\n      2. ordered two\n  - back to two\n- one again\n\n1. step\n\n   ```sh\n   run --it\n   ```\n\n   after the code\n2. step two\n   > a quote in an item\n3. step three\n\n   | a | b |\n   |---|---|\n   | 1 | 2 |\n\n   and text\n4. last\n\n- ```\n  fenced first\n  ```\n- next\n\n-   wide marker\n    still the item\n\n        code in the item\n\nAfter."
        // A delimiter row that arrives after the line it makes a header, or does not.
        readonly property string lateTables: "Text before\nx | y\n--|--\n1 | 2\n\nText before\nx | y\n--|--|--\nnot a table\n\n- item\nx | y\n--|--\n1 | 2\n\n- item\nx | y\n--|-- no\n\n> quote\nx | y\n--|--\n1 | 2\n\n> quote\nx | y\nplain\n\n    code\nx | y\n--|--\n\nx | y\n===\n\nEnd | of | text\n---|---|---"
        // A reply as an agent writes one.
        readonly property string agentReply: "## Cart totals\n\nDiscounts apply **before** tax, so the order is:\n\n1. Sum the lines\n2. Apply discounts\n   - coupon first\n   - then loyalty\n3. Add tax\n\n```ts\nconst total = lines.reduce((sum, line) => sum + line.price, 0);\nreturn roundToCent(total * (1 + rate));\n```\n\n| Region | Rate |\n|---|---:|\n| EU, north | 21% |\n| US | 0% |\n\n> [!WARNING]\n> Old carts keep their totals.\n\nSee [the pricing docs][pricing] or `src/cart.ts`.\n\n[pricing]: https://example.com/docs/pricing\n"

        // Texts with every block and inline form js/markdown.js reads, and
        // the forms whose reading depends on the text that follows them: a
        // setext underline, a lazy line, a table's delimiter row, a link
        // definition after its uses, a fence not yet closed, a list that a
        // later item makes loose.
        readonly property var corpus: [
            // Headings and rules.
            "# One\n## Two ##\n### Three\n#### Four\n##### Five\n###### Six\n####### not a heading\n#\n#hashtag\n\nSetext one\n===\n\nSetext two\nover two lines\n---\n\n---\n***\n_ _ _\n- - -\n\nAfter the rules.",
            // What the next line makes of a paragraph.
            "Title\n=\n\nA paragraph that waits\n-\n\nNot an underline\n= x\n\nText\n- item after text\n\nText\n2. not a list\n1. a list\n\nline one\nline two\n   line three\n\nlast",
            // Inline forms.
            "Plain *em* and **strong** and ***both*** and _under_ and __dunder__ and snake_case_word and ~~struck~~ and ~one~ and ~~~three~~~ and **open.\nA soft break, then a hard one  \nwith two spaces and one with a backslash\\\nand a `code span`, `` a ` tick ``, ` padded `, `unclosed.\n\nEscapes \\* \\_ \\# \\[ \\] \\\\ and \\a stay; entities &amp; &lt; &copy; &#35; &#x1F600; &nope; &#0; decode or stay.\n\n<script>alert(1)</script> <b>bold?</b> line<br>break<br/>again <br >.",
            // Links, images, autolinks and link definitions.
            "[inline](https://example.com/a_(b) \"title\") [angle](<https://example.com/a b>) [unsafe](javascript:alert(1)) [path](src/app.ts#L3) [drive](C:\\x) ![image](https://example.com/i.png) ![](alt.png) [[nested](a)](b) [a [b] c](d) [unclosed](x\n\n<https://auto.example> <mailto:a@b.co> <a@b.co> <not a link> www.example.com, https://example.com/x). (https://example.com/(y)) http://x.y/z?q=1&r=2!\n\n[full][Docs] [collapsed][] [shortcut] [Shortcut  \n] [missing][nope] [constructor] [__proto__] ![pic][docs] [*em* label][docs]\n\n[docs]: https://example.com/docs \"Title\"\n[DOCS]: https://example.com/second\n[collapsed]: <https://example.com/c>\n[shortcut]: /relative 'single'\n[bad]: javascript:alert(1)\n[constructor]: https://example.com/ctor\nNot a definition any more.",
            lateDefinitions,
            // A definition that more text turns back into a paragraph.
            "Uses [a] and [b].\n\n- and [a] here\n\n[a]: https://example.com/a and then words\n[b]: https://example.com/b\n\n[b]: https://example.com/b2\n[b] is used.\n",
            // Fences.
            "Before\n\n```js\nconst a = 1 < 2;\n\n# not a heading\n- not a list\n```\nRight after.\n\n~~~python title=\"app.py\"\nprint('~~~')\n```\n~~~\n\n````\n```\ninner\n```\n````\n\n``` {.rust} src/main.rs\nfn main() {}\n```\n\n```gitignore\nnode_modules\n```\n\n  ```\n  indented fence\n    keeps this\n  ```\n\n``` not `a` fence\n\n```\nnever closed\n\n# still code",
            // Indented code.
            "Para\n\n    indented code\n\n    after a blank\n\tand a tab\nNot code.\n\n    last\n\n\n",
            // Quotes and alerts.
            "> quote one\nlazy continuation\n> still the quote\n\n> second quote\n> > nested quote\n> > deeper\n>\n> - list in quote\n> ```\n> code in quote\n> ```\n\n> [!NOTE]\n> A note.\n\n> [!tip]\n> lower case\n\n> [!IMPORTANT]\n> x\n\n> [!WARNING]\n> x\n\n> [!CAUTION]\n> x\n\n> [!NOTE] not an alert\n\n>no space\n# heading ends it\n> quote\n- list ends it\n> quote\n```\nfence ends it\n```\n> quote\n---\n> a | b\n> ---|---\n",
            // Lists.
            "- one\n- two\n  continued\nlazy\n- three\n\n+ plus list\n+ again\n\n* star\n* star two\n\n1. first\n2. second\n3) other delimiter\n4) again\n\n7. starts at seven\n8. eight\n\n100. wide\n101. gutter\n\n- [ ] todo\n- [x] done\n- [X] DONE\n- [ ]not a task\n-\n- after an empty item\n\n- loose\n\n- list\n\n  with a paragraph\n\n- tight again?\n\nText\n- interrupts\n\nText\n3. does not interrupt\n\n- item\n---\n- item\n***\nEnd.",
            nestedBlocks,
            // Tables.
            "Intro line\n| Left | Center | Right |\n|:-----|:------:|------:|\n| a | b | c |\n| *em* | `code` | [l](https://example.com) |\n| short |\n| too | many | cells | here |\n| esc \\| pipe | x | y |\n\nNo | leading | pipes\n---|---|---\n1 | 2 | 3\n# heading ends the table\n\n| a | b |\n|---|---|\n> quote ends it\n\n| a | b |\n|---|---|\n```\nfence ends it\n```\n\n| a | b |\n|---|---|\n***\n\n| header | only |\n|---|---|\n\n| not | a table |\n|---|\n\n| nor | this |\n| --- | --- | --- |\n\na | b\n-|-\n",
            lateTables,
            // Quote links: one in a line, several, one in a list, a malformed one, the old scheme.
            "Why? " + quoteLink + " Thanks.\n\nNext paragraph.\n\n" + quoteLink + "\n" + quoteLink + quoteLink + " tail\n- item " + quoteLink + "\n\n[Assistant quote](hal-c2-citation://v1/env/thread?text=a&start=0&end=1&prefix=&suffix=) is malformed, [Assistant quote](t3-citation://v1/e/t/m?text=old+scheme%0D%0Awith+CRLF&start=0&end=1&prefix=p&suffix=s) is the old scheme.\n\nEnd.",
            // Text that is not ASCII.
            "H\u00e9llo w\u00f6rld \u2014 \u201cquotes\u201d \u2026 na\u00efve caf\u00e9.\n\n\u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8\u3001**\u592a\u5b57**\u3068`\u30b3\u30fc\u30c9`\u3002\n\n- \u0395\u03bb\u03bb\u03b7\u03bd\u03b9\u03ba\u03ac\n- \u0627\u0644\u0639\u0631\u0628\u064a\u0629\n- \u05e2\u05d1\u05e8\u05d9\u05ea\n\n\ud83d\ude00 emoji \ud83d\udc68\u200d\ud83d\udc69\u200d\ud83d\udc67\u200d\ud83d\udc66 family \ud83c\uddee\ud83c\uddf8 flag e\u0301 combining\n\n| \u540d\u524d | \u5024 |\n|---|---|\n| \ud83d\ude00 | \u2713 |\n\n```\n\ud83d\ude00 in code \u2192 \u2713\n```\n\n[\u30ea\u30f3\u30af](https://example.com/\u65e5\u672c\u8a9e) *\ud83d\ude00* _\u00e9_ ~~\u00f6~~\u2028line separator\u00a0nbsp",
            // CRLF, and bare carriage returns.
            "# Title\r\n\r\nPara one\r\nline two\r\n\r\n- a\r\n- b\r\n\r\n```js\r\ncode\r\n```\r\n\r\n| a | b |\r\n|---|---|\r\n| 1 | 2 |\r\n\r\n> quote\r\n\r\nSetext\r\n===\r\n\r\n[r]: /x\r\n[r]\r\n",
            "old mac\rline two\r\rnew para\r# heading\r\n\nmixed\n\r\nend\r- a\r\r- b\r",
            // A quote link after a bare carriage return, whose line feed joins it.
            "~~~\r" + quoteLink + "\rcode\r~~~\r" + quoteLink + "\r\r- item\r" + quoteLink + " tail\r    code\r" + quoteLink + "\r\n" + quoteLink + "\rend",
            // Tabs.
            "\t# not a heading (code)\n\n-\ttab after marker\n\t- nested by tab\n\n1.\tordered\n\n```\n\tcode\ttabs\n```\n\na\tb\tc\n\n>\tquote tab\n\n|\ta\t|\tb\t|\n|---|---|\n \t \n  \t\ntext",
            // Blank lines and indents.
            "\n\n   \n  leading blank lines\n   indented three\n    four is still the paragraph\ntrailing spaces   \n\n\n\n   # indented heading\n    # code\n\n ---\n  - - -\n   ***\n\nend   \n\n\n",
            // Very long lines.
            ("word ".repeat(120) + "**bold** [link](https://example.com) ").repeat(3) + "\n\n" + "x".repeat(1500) + "\n\n- " + "item ".repeat(200) + "\n\n```\n" + "c".repeat(1200) + "\n```\n\n| " + "cell ".repeat(100) + "| b |\n|---|---|\n\nEnd.",
            agentReply,
            // The shortest texts.
            "", "\n", "x", "#", "-", ">", "```", "|", "\r", "[", "    ", "\t"
        ]

        // Where a text is cut as it grows: every `size` characters, after
        // every line ("lines"), or at uneven steps from `seed` ("random": of 1
        // to 23 characters, and of up to 400 in a long text).
        function cutsOf(text, size, seed) {
            const span = text.length > 1500 ? 400 : 23;
            const cuts = [];
            let at = 0;
            let random = (seed ?? 0) + 1;
            while (at < text.length) {
                if (size === "lines") {
                    const next = text.slice(at).search(/[\r\n]/);
                    at = next < 0 ? text.length : at + next + 1;
                } else if (size === "random") {
                    random = random * 48271 % 2147483647;
                    at = Math.min(text.length, at + 1 + random % span);
                } else {
                    at = Math.min(text.length, at + size);
                }
                cuts.push(at);
            }
            if (cuts.length === 0)
                cuts.push(0);
            return cuts;
        }

        // Whether the first `count` segments of `a` are those of `b`, field by field.
        function sameSegments(a, b, count) {
            const fields = ["kind", "html", "code", "language", "title", "open", "indent", "payload", "alert", "top", "bottom", "gap"];
            if (a.length < count || b.length < count)
                return false;
            for (let s = 0; s < count; ++s) {
                for (const field of fields) {
                    if (a[s][field] !== b[s][field])
                        return false;
                }
            }
            return true;
        }

        // Reads `text` as it grows by `cuts` and holds every step to what the
        // text so far reads as in one go. Returns what went wrong, or "".
        function grownWrong(text, cuts, options) {
            const state = Md.state();
            let last = [];
            for (const cut of cuts) {
                const prefix = text.slice(0, cut);
                const got = Md.segments(prefix, options, state);
                const want = Md.segments(prefix, options);
                if (got.length !== want.length || !sameSegments(got, want, want.length))
                    return "at " + cut + " of " + JSON.stringify(text) + "\n got: " + JSON.stringify(got) + "\nwant: " + JSON.stringify(want);
                // The segments it calls stable are the ones it returned last.
                if (state.stable > got.length || !sameSegments(got, last, state.stable))
                    return "at " + cut + " of " + JSON.stringify(text) + ": the first " + state.stable + " segments are not the last ones";
                last = got.map(segment => Object.assign({}, segment));
            }
            // The other way to fold the same text (the reply finishes), and back.
            for (const streaming of [!options.streaming, !!options.streaming]) {
                const flipped = { streaming: streaming, lineBreaks: options.lineBreaks };
                const got = Md.segments(text, flipped, state);
                const want = Md.segments(text, flipped);
                if (got.length !== want.length || !sameSegments(got, want, want.length))
                    return "folded " + (streaming ? "streaming" : "finished") + ": " + JSON.stringify(text);
            }
            return "";
        }

        // However a text arrives, it reads as it does in one go: in steps of
        // one character (every cut there is), of a few, of a line, and of
        // uneven lengths. Line breaks change what a paragraph renders as and
        // nothing of how a text is cut, so those rows take fewer steps.
        function test_growingTextReadsAsTheWholeText_data() {
            return [
                { tag: "streaming", options: { streaming: true, lineBreaks: false }, sizes: [1, 3, 7, "lines", "random", "random"] },
                { tag: "not streaming", options: { streaming: false, lineBreaks: false }, sizes: [1, 7, "lines", "random"] },
                { tag: "streaming user message", options: { streaming: true, lineBreaks: true }, sizes: [3, "lines", "random"] },
                { tag: "user message", options: { streaming: false, lineBreaks: true }, sizes: [2, "lines", "random"] }
            ];
        }

        function test_growingTextReadsAsTheWholeText(data) {
            let steps = 0;
            for (let d = 0; d < corpus.length; ++d) {
                const text = corpus[d];
                // Every cut of the longest text would take a minute and show
                // nothing the cuts of the others do not.
                const sizes = text.length > 1500 ? [173, "lines", "random"] : data.sizes;
                for (let s = 0; s < sizes.length; ++s) {
                    const cuts = cutsOf(text, sizes[s], d * 31 + s);
                    steps += cuts.length;
                    const wrong = grownWrong(text, cuts, data.options);
                    if (wrong.length > 0)
                        fail("text " + d + " in steps of " + sizes[s] + ", " + wrong);
                }
            }
            verify(steps > 2000, "the corpus is read in " + steps + " steps");
        }

        // A text that is replaced, not lengthened, is read from its start,
        // and so is one whose line breaks start or stop counting.
        function test_replacedTextIsReadAnew() {
            const state = Md.state();
            for (let d = 0; d + 1 < corpus.length; ++d) {
                const options = { streaming: d % 3 !== 2, lineBreaks: false };
                for (const text of [corpus[d].slice(0, corpus[d].length >> 1), corpus[d], corpus[d + 1], corpus[d + 1] + "\n\nmore", "x" + corpus[d + 1] + "\n\nmore"]) {
                    compare(JSON.stringify(Md.segments(text, options, state)), JSON.stringify(Md.segments(text, options)), "text " + d);
                    options.lineBreaks = !options.lineBreaks;
                    compare(JSON.stringify(Md.segments(text, options, state)), JSON.stringify(Md.segments(text, options)), "text " + d + ", line breaks " + options.lineBreaks);
                }
            }
        }

        // The work a delta costs is the block it lengthens, however long the
        // reply before it: what `takeTally` counts, never a time.
        function test_deltaCostsTheBlockItLengthens() {
            const blocks = ["A paragraph of the reply, with *emphasis*, `code` and a [link](https://example.com/docs).", "- one\n- two\n  - nested\n- three", "```ts\nconst total = lines.reduce((sum, line) => sum + line.price, 0);\nreturn total;\n```", "| Region | Rate |\n|---|---:|\n| EU | 21% |", "> A quote\n> of two lines.", "## A heading"];
            let reply = "";
            for (let b = 0; b < 600; ++b)
                reply += blocks[b % blocks.length] + "\n\n";
            const options = { streaming: true, lineBreaks: false };

            Md.takeTally();
            const whole = Md.segments(reply, options);
            const inOneGo = Md.takeTally();
            compare(inOneGo.chars, reply.length);
            compare(inOneGo.blocks, 600);
            compare(inOneGo.flowed, 600);
            verify(inOneGo.lines > 1800, inOneGo.lines + " lines");

            const state = Md.state();
            Md.segments(reply, options, state);
            Md.takeTally();

            // A paragraph grows by a character at a time.
            const last = "The last paragraph grows, **word** by word, and is all a delta costs.";
            for (let n = 1; n <= last.length; ++n) {
                const got = Md.segments(reply + last.slice(0, n), options, state);
                const cost = Md.takeTally();
                compare(cost.chars, n, "characters read at " + n);
                compare(cost.lines, 1, "lines read at " + n);
                compare(cost.blocks, 1, "blocks parsed at " + n);
                compare(cost.flowed, 1, "blocks rendered at " + n);
                compare(got.length, whole.length + 1);
                compare(state.stable, whole.length, "segments left alone at " + n);
            }

            // A code block grows by a line at a time: its own lines, no others.
            let text = reply + last + "\n\n```py\n";
            Md.segments(text, options, state);
            Md.takeTally();
            for (let n = 1; n <= 40; ++n) {
                text += "print(" + n + ")\n";
                const got = Md.segments(text, options, state);
                const cost = Md.takeTally();
                compare(cost.lines, n + 2, "lines read at code line " + n);
                compare(cost.blocks, 1);
                compare(cost.flowed, 1);
                compare(state.stable, got.length - 1);
            }

            // A list waits for the line after it, so the paragraph under a
            // list is parsed with it, and the list is not rendered again.
            text += "```\n\n- one\n- two\n\n";
            Md.segments(text, options, state);
            Md.takeTally();
            for (const word of ["Under", " the", " list."]) {
                text += word;
                Md.segments(text, options, state);
                const cost = Md.takeTally();
                compare(cost.blocks, 2);
                compare(cost.flowed, 1);
                compare(cost.lines, 4);
            }

            // The reply finishes: its prose is merged from what was rendered.
            const done = Md.segments(text, { streaming: false, lineBreaks: false }, state);
            const finishing = Md.takeTally();
            compare(finishing.chars, 0);
            compare(finishing.flowed, 0);
            compare(JSON.stringify(done), JSON.stringify(Md.segments(text, { streaming: false, lineBreaks: false })));

            // A text that grows without streaming (a quote in a reply that
            // streams) is read whole twice, then from its tail like any other.
            const quote = Md.state();
            Md.segments(reply, {}, quote);
            Md.segments(reply + "Then", {}, quote);
            Md.takeTally();
            const grown = Md.segments(reply + "Then more.", {}, quote);
            const growing = Md.takeTally();
            compare(growing.chars, "Then more.".length);
            compare(growing.blocks, 1);
            compare(growing.flowed, 1);
            compare(JSON.stringify(grown), JSON.stringify(Md.segments(reply + "Then more.", {})));
        }

        // A definition reaches back: the blocks that used its label are
        // rendered again, and no others.
        function test_lateDefinitionRedrawsOnlyItsUsers() {
            let reply = "";
            for (let b = 0; b < 200; ++b)
                reply += (b % 50 === 7 ? "Paragraph " + b + " cites [the docs][docs]." : "Paragraph " + b + " cites nothing, though it has [brackets].") + "\n\n";
            const options = { streaming: true, lineBreaks: false };
            const state = Md.state();
            Md.segments(reply, options, state);
            Md.takeTally();
            const linked = Md.segments(reply + "[docs]: https://example.com/docs", options, state);
            const cost = Md.takeTally();
            compare(cost.blocks, 1, "only the definition is parsed");
            compare(cost.flowed, 4, "the four paragraphs that cite it");
            compare(JSON.stringify(linked), JSON.stringify(Md.segments(reply + "[docs]: https://example.com/docs", options)));
            verify(linked[7].html.indexOf("<a href=\"https://example.com/docs\">the docs</a>") >= 0, linked[7].html);
        }

        // A finished text is kept for the next brick that shows it; a text
        // that grows leaves none of its lengths behind.
        function test_onlyFinishedTextsAreKept() {
            const text = "# Kept\n\nA finished reply no other test reads.";
            const brick = Md.state();
            Md.takeTally();
            const first = Md.segments(text, {}, brick);
            verify(Md.takeTally().chars > 0);
            compare(brick.stable, 0);
            // The brick asks again (its flags are bound one by one): nothing to do.
            verify(Md.segments(text, {}, brick) === first);
            compare(brick.stable, first.length);
            verify(Md.segments(text, {}, Md.state()) === first, "the next brick gets the same segments");
            compare(Md.takeTally().chars, 0);

            const state = Md.state();
            for (let n = 1; n <= text.length; ++n)
                Md.segments(text.slice(0, n) + "!", { streaming: true }, state);
            Md.takeTally();
            for (let n = 1; n < text.length; ++n) {
                Md.segments(text.slice(0, n) + "!", {}, Md.state());
                verify(Md.takeTally().chars > 0, "a length of the streamed text was kept: " + n);
            }
        }

        // The brick shows a streamed reply as the library reads it, step by
        // step, and the finished reply as a brick made with the whole text.
        function test_streamedBrickShowsWhatItsTextReadsAs() {
            const roles = ["kind", "html", "code", "language", "title", "open", "indent", "payload", "alert", "gap"];
            const shown = md => segmentsOf(md).sort((a, b) => a.index - b.index).map(item => JSON.stringify(roles.map(role => item[role])));
            const read = (text, streaming) => Md.segments(text, { streaming: streaming, lineBreaks: false }).map(segment => JSON.stringify(roles.map(role => segment[role])));
            for (const text of [lateDefinitions, nestedBlocks, lateTables, agentReply]) {
                const d = corpus.indexOf(text);
                const md = make("", { streaming: true });
                for (const cut of cutsOf(text, "random", d)) {
                    md.text = text.slice(0, cut);
                    compare(shown(md), read(md.text, true), "text " + d + " at " + cut);
                }
                md.streaming = false;
                compare(shown(md), read(text, false), "text " + d + " finished");
                compare(shown(md), shown(make(text)), "text " + d + " made whole");
            }
        }

        // Nothing is touched but the block a delta lengthens: no other
        // segment's text is set again, however many there are.
        function test_deltaTouchesOnlyTheLastSegment() {
            let reply = "";
            for (let b = 0; b < 40; ++b)
                reply += "Paragraph " + b + " of the reply.\n\n```\ncode " + b + "\n```\n\n";
            const md = make(reply + "The last", { streaming: true });
            const before = segmentsOf(md);
            compare(before.length, 81);
            let rewrites = 0;
            for (let s = 0; s < 80; ++s) {
                const edit = prose(before[s]) ?? findChild(before[s], "codeText");
                edit.textChanged.connect(() => ++rewrites);
            }
            for (const word of [" paragraph", " grows", " by", " words."])
                md.text += word;
            const after = segmentsOf(md);
            compare(after.length, 81);
            for (let s = 0; s < 81; ++s)
                verify(after[s] === before[s], "segment " + s + " keeps its item");
            compare(rewrites, 0);
            verify(plain(prose(after[80])).endsWith("grows by words."));
        }
    }
}

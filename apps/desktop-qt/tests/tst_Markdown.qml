import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

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
    }
}

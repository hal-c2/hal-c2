import QtQuick
import QtQuick.Controls
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The right-click menus on text: the composer's Cut, Copy, Paste and Select
// All, and Copy and Select All on a reply (TextEditMenu).
Item {
    id: root
    width: 900
    height: 700

    Component {
        id: composerComponent
        Composer {
            width: 800
            height: 650
        }
    }

    Component {
        id: markdownComponent
        Markdown {
            width: 560
        }
    }

    TestCase {
        name: "TextEditMenu"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function cleanup() {
            Shell.reset();
        }

        function composerInput() {
            const composer = createTemporaryObject(composerComponent, root);
            verify(composer);
            const input = findChild(composer, "input");
            verify(input);
            input.forceActiveFocus();
            return [composer, input];
        }

        function entry(menu, name) {
            for (let i = 0; i < menu.count; ++i) {
                if (menu.itemAt(i).objectName === name)
                    return menu.itemAt(i);
            }
            return null;
        }

        function choose(menu, name) {
            const item = entry(menu, name);
            verify(item, name);
            verify(item.visible && item.enabled, name + " can be chosen");
            // An item takes clicks once the menu has finished opening.
            tryCompare(menu, "opened", true);
            mouseClick(item);
            // A reply's menu is gone once closed.
            tryVerify(() => menu.visible !== true);
        }

        function rightClick(item, x, y) {
            mouseClick(item, x, y, Qt.RightButton);
        }

        function test_theComposersMenuCutsAndCopiesTheSelection() {
            const [composer, input] = composerInput();
            input.text = "fix the cart totals";
            input.select(4, 8);
            const menu = findChild(composer, "editorMenu");
            rightClick(input, 10, 10);
            tryCompare(menu, "visible", true);
            compare(["cutText", "copyText", "pasteText", "selectAllText"].filter(n => entry(menu, n).visible).length, 4);
            // Qt's own TextArea menu does not open beside it.
            verify(!(input.ContextMenu.menu?.visible ?? false));
            choose(menu, "copyText");
            compare(Shell.clipboardText(), "the ");
            compare(input.text, "fix the cart totals");

            input.select(0, 4);
            rightClick(input, 10, 10);
            tryCompare(menu, "visible", true);
            choose(menu, "cutText");
            compare(input.text, "the cart totals");
        }

        function test_theComposersPasteGoesIntoTheDraft() {
            const [composer, input] = composerInput();
            input.text = "fix totals";
            input.cursorPosition = 4;
            Shell.setClipboardText("the cart ");
            const menu = findChild(composer, "editorMenu");
            rightClick(input, 10, 10);
            tryCompare(menu, "visible", true);
            choose(menu, "pasteText");
            compare(input.text, "fix the cart totals");
        }

        // A copied picture attaches, as the paste key does.
        function test_theComposersPasteAttachesACopiedPicture() {
            const [composer, input] = composerInput();
            Shell.clipboardAttachments = [{ name: "image.png", mimeType: "image/png", base64: "AA==" }];
            const menu = findChild(composer, "editorMenu");
            rightClick(input, 10, 10);
            tryCompare(menu, "visible", true);
            choose(menu, "pasteText");
            const attach = Shell.dispatchedActions.find(a => a.action === "composer.attach");
            verify(attach);
            compare(attach.payload.files[0].name, "image.png");
            compare(input.text, "");
        }

        function test_theMenuKeyOpensTheComposersMenu() {
            const [composer, input] = composerInput();
            input.text = "fix";
            const menu = findChild(composer, "editorMenu");
            keyClick(Qt.Key_Menu);
            tryCompare(menu, "visible", true);
            choose(menu, "selectAllText");
            compare(input.selectedText, "fix");
        }

        function test_aReplysTextOffersCopyAndSelectAll() {
            const md = createTemporaryObject(markdownComponent, root, { text: "Refunds reuse the old rate." });
            verify(md);
            const edit = findChild(md, "markdownProse");
            verify(edit);
            const from = edit.positionToRectangle(0);
            const to = edit.positionToRectangle(7);
            mouseDrag(edit, from.x, from.y + from.height / 2, to.x - from.x, 0);
            compare(edit.selectedText, "Refunds");
            rightClick(edit, to.x + 20, to.y + to.height / 2);
            let menu = findChild(md, "textMenu");
            verify(menu);
            tryCompare(menu, "visible", true);
            verify(!entry(menu, "cutText").visible);
            verify(!entry(menu, "pasteText").visible);
            choose(menu, "copyText");
            compare(Shell.clipboardText(), "Refunds");

            rightClick(edit, to.x + 20, to.y + to.height / 2);
            tryVerify(() => findChild(md, "textMenu")?.visible ?? false);
            choose(findChild(md, "textMenu"), "selectAllText");
            compare(edit.selectedText, "Refunds reuse the old rate.");
        }

        function test_aCodeBlockOffersCopy() {
            const md = createTemporaryObject(markdownComponent, root, { text: "```\nconst rate = 1;\n```" });
            verify(md);
            const code = findChild(md, "codeText");
            verify(code);
            rightClick(code, 4, 4);
            tryVerify(() => findChild(md, "textMenu")?.visible ?? false);
            choose(findChild(md, "textMenu"), "selectAllText");
            compare(code.selectedText.trim(), "const rate = 1;");
        }

        // A link keeps its own menu.
        function test_aLinkOpensTheLinksMenu() {
            const md = createTemporaryObject(markdownComponent, root, { text: "See [the docs](https://example.com/docs)." });
            verify(md);
            const edit = findChild(md, "markdownProse");
            const at = edit.positionToRectangle(6);
            rightClick(edit, at.x + 2, at.y + at.height / 2);
            const menu = Shell.dispatchedActions.find(a => a.action === "link.menu");
            verify(menu);
            compare(menu.payload.url, "https://example.com/docs");
            verify(!(findChild(md, "textMenu")?.visible ?? false));
        }
    }
}

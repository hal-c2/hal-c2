import QtQuick
import QtTest
import QtQuick.Controls
import "../qml/HalC2/Bricks"
import HalC2.Shell

// The CommandPalette brick over the Palette mock: it follows `open`, takes the
// keyboard when it opens, and hands its keys to the palette.
Item {
    id: root
    width: 800
    height: 600

    Component { id: component; CommandPalette {} }

    TestCase {
        name: "CommandPaletteTests"
        when: windowShown

        function init() {
            PaletteModel.clear();
            for (let n = 1; n <= 3; ++n)
                PaletteModel.append({ title: "Entry " + n, description: "", group: "Actions", shortcut: "", kind: "action", runnable: true, current: false });
            PaletteModel.highlighted = 0;
            PaletteModel.query = "";
            PaletteModel.ran = [];
            PaletteModel.open = false;
            PaletteModel.mode = "command";
            PaletteModel.submitLabel = "";
            PaletteModel.submitShortcut = "";
            PaletteModel.submenu = "";
            PaletteModel.calls = [];
        }

        function opened() {
            const popup = createTemporaryObject(component, root);
            verify(!!popup);
            PaletteModel.show();
            tryCompare(popup, "opened", true);
            const field = findChild(popup.contentItem, "commandPaletteSearch");
            verify(!!field);
            tryVerify(() => field.activeFocus, 1000, "the search field has the keyboard");
            return popup;
        }

        function test_opensWithTheSearchFieldFocused() {
            opened();
        }

        // The palette is as tall as its rows, up to its cap; with none it
        // still has room to say so.
        function test_heightFollowsTheRows() {
            const popup = opened();
            const list = findChild(popup.contentItem, "commandPaletteList");
            tryVerify(() => list.itemAtIndex(2) !== null);
            // The fit is set once the rows settle, a frame after they appear.
            tryVerify(() => list.height === list.contentHeight, 2000, "the list is as tall as its rows, not " + list.height);
            const three = popup.height;
            verify(three < 300, "three rows make a short palette, not " + three);
            verify(!findChild(list, "scrollThumb").visible, "no bar when every row shows");
            PaletteModel.clear();
            tryVerify(() => popup.height < three, 2000, "no rows make it shorter still");
            verify(list.height > 0, "with room for the empty text");
            for (let n = 1; n <= 40; ++n)
                PaletteModel.append({ title: "Entry " + n, description: "", group: "Actions", shortcut: "", kind: "action", runnable: true, current: false });
            // It stops at the cap on a whole row, not a sliced one...
            tryVerify(() => popup.height <= 480 && popup.height > 480 - 34, 2000, "near the cap, not " + popup.height);
            let last = null;
            for (let i = 0; i < list.count && list.itemAtIndex(i); ++i)
                if (list.itemAtIndex(i).y + list.itemAtIndex(i).height === list.height)
                    last = i;
            verify(last !== null, "a row ends where the list does");
            // ...and the rows past it are hinted at by a bar at the edge.
            // A thin bar at the right edge says there is more: at the top, then at the end.
            const thumb = findChild(list, "scrollThumb");
            verify(thumb.visible);
            verify(Math.abs(thumb.y - Theme.space.xxs) < 0.5, "the bar starts at the top, not " + thumb.y);
            verify(thumb.height < list.height - 2 * Theme.space.xxs);
            verify(thumb.x >= list.width - Theme.space.sm, "the bar keeps to the rows' right padding");
            list.positionViewAtEnd();
            tryVerify(() => Math.abs(thumb.y + thumb.height - (list.height - Theme.space.xxs)) < 0.5, 2000, "the bar ends at the bottom, not " + thumb.y);
        }

        // A submenu's long list, under its title and without group headers,
        // also ends on a whole row at full ink, with the bar beside it.
        function test_aLongSubmenuEndsOnAWholeRowAndHintsAtMore() {
            const popup = opened();
            const list = findChild(popup.contentItem, "commandPaletteList");
            for (let n = 4; n <= 20; ++n)
                PaletteModel.append({ title: "Entry " + n, description: "", group: n < 10 ? "Actions" : "Threads", shortcut: "", kind: "action", runnable: true, current: false });
            tryVerify(() => findChild(list, "scrollThumb").visible);
            // As the palette moves into a submenu: its rows go and come
            // (no reset), and the title above the search shows after them.
            PaletteModel.remove(0, PaletteModel.count);
            for (let n = 1; n <= 13; ++n)
                PaletteModel.append({ title: "project-" + n, description: "/home/me/dev/project-" + n, group: "", shortcut: "", kind: "project", runnable: true, current: false });
            PaletteModel.submenu = "New thread in...";
            tryVerify(() => list.contentHeight > 13 * 34 - 1);
            verify(list.height < list.contentHeight, "the list scrolls, " + list.height + " of " + list.contentHeight);
            tryVerify(() => {
                for (let i = 0; i < list.count && list.itemAtIndex(i); ++i)
                    if (list.itemAtIndex(i).y + list.itemAtIndex(i).height === list.height)
                        return true;
                return false;
            }, 2000, "a row ends where the list does, at " + list.height);
            const edge = findChild(list, "scrollThumb");
            verify(edge.visible);
            // Nothing paints over the last whole row's text: it holds the
            // same ink with the bar as without it.
            function lastRowInk() {
                const img = grabImage(Overlay.overlay);
                const o = list.mapToItem(Overlay.overlay, 0, list.height - Theme.control.md);
                let sum = 0;
                for (let y = 2; y < Theme.control.md - 2; ++y)
                    for (let x = 0; x < Math.min(300, list.width - Theme.space.sm); x += 2) {
                        const c = Qt.color(img.pixel(o.x + x, o.y + y));
                        sum += c.r + c.g + c.b;
                    }
                return sum;
            }
            const shown = lastRowInk();
            edge.visible = false;
            waitForRendering(list);
            const plain = lastRowInk();
            compare(shown, plain, "the last row keeps its ink");
        }

        // Rows are list items named by their title, for assistive technology.
        function test_rowsAreNamedListItems() {
            const popup = opened();
            const list = findChild(popup.contentItem, "commandPaletteList");
            verify(!!list);
            compare(list.Accessible.role, Accessible.List);
            tryVerify(() => list.itemAtIndex(0) !== null);
            const item = list.itemAtIndex(0);
            compare(item.Accessible.role, Accessible.ListItem);
            verify(item.Accessible.name.startsWith("Entry 1"));
        }

        function test_escapeDismisses() {
            const popup = opened();
            keyClick(Qt.Key_Escape);
            tryCompare(popup, "opened", false);
            compare(PaletteModel.open, false);
        }

        function test_escapeInAModeGoesBackToCommands() {
            const popup = opened();
            PaletteModel.mode = "files";
            keyClick(Qt.Key_Escape);
            compare(PaletteModel.mode, "command");
            compare(popup.opened, true);
        }

        function test_backspaceOnAnEmptyFieldLeavesTheSubmenu() {
            opened();
            PaletteModel.submenu = "Change theme";
            keyClick(Qt.Key_Backspace);
            compare(PaletteModel.submenu, "");
            compare(PaletteModel.calls, ["leaveSubmenu"]);
        }

        function test_theFieldFollowsTheQueryThePaletteMovesTo() {
            const popup = opened();
            const field = findChild(popup.contentItem, "commandPaletteSearch");
            PaletteModel.query = "~/code/";
            compare(field.text, "~/code/");
        }

        function test_modEnterAddsTheBrowsedFolder() {
            opened();
            keyClick(Qt.Key_Return, Qt.ControlModifier);
            compare(PaletteModel.calls, ["addBrowsedFolder"]);
        }

        function test_theBrowserNamesWhatEnterDoes() {
            const popup = opened();
            const submit = findChild(popup.contentItem, "commandPaletteSubmit");
            verify(!submit.visible, "nothing to add outside the folder browser");
            PaletteModel.mode = "browse";
            PaletteModel.submitLabel = "Create & Add";
            PaletteModel.submitShortcut = "Enter";
            verify(submit.visible);
            compare(submit.text, "Create & Add  Enter");
            PaletteModel.submitShortcut = "Ctrl+Enter";
            compare(submit.text, "Create & Add  Ctrl+Enter");
            mouseClick(submit);
            compare(PaletteModel.calls, ["addBrowsedFolder"]);
        }

        function test_typingSetsTheQuery() {
            opened();
            keyClick(Qt.Key_T);
            compare(PaletteModel.query, "t");
        }

        function test_arrowsAndEnterRunTheHighlight() {
            const popup = opened();
            keyClick(Qt.Key_Down);
            compare(PaletteModel.highlighted, 1);
            keyClick(Qt.Key_Return);
            compare(PaletteModel.ran, [1]);
            tryCompare(popup, "opened", false);
        }

        function test_onlyAPointerThatMovesTakesTheHighlight() {
            const popup = opened();
            const list = findChild(popup.contentItem, "commandPaletteList");
            verify(!!list);
            tryVerify(() => list.itemAtIndex(2) !== null);
            const at = list.itemAtIndex(2).mapToItem(list, 20, 10);
            mouseMove(list, at.x, at.y);
            mouseMove(list, at.x + 1, at.y);
            compare(PaletteModel.highlighted, 2);
            // New rows load under the resting pointer.
            PaletteModel.clear();
            for (let n = 1; n <= 3; ++n)
                PaletteModel.append({ title: "Folder " + n, description: "", group: "Directories", shortcut: "", kind: "action", runnable: true, current: false });
            PaletteModel.highlighted = 0;
            tryVerify(() => list.itemAtIndex(2) !== null);
            mouseMove(list, at.x + 1, at.y);
            compare(PaletteModel.highlighted, 0);
            mouseMove(list, at.x + 2, at.y);
            compare(PaletteModel.highlighted, 2);
            // The pointer moves over an empty list, and rows load under it there.
            PaletteModel.clear();
            PaletteModel.highlighted = -1;
            tryVerify(() => list.count === 0);
            mouseMove(list, at.x + 5, at.y);
            for (let n = 1; n <= 3; ++n)
                PaletteModel.append({ title: "Folder " + n, description: "", group: "Directories", shortcut: "", kind: "action", runnable: true, current: false });
            tryVerify(() => list.itemAtIndex(2) !== null);
            mouseMove(list, at.x + 5, at.y);
            compare(PaletteModel.highlighted, -1);
            mouseMove(list, at.x + 6, at.y);
            compare(PaletteModel.highlighted, 2);
        }

        function test_numberShortcutRunsTheNthEntry() {
            opened();
            keyClick(Qt.Key_3, Qt.ControlModifier);
            compare(PaletteModel.ran, [2]);
        }

        function test_closingTheShellPaletteClosesThePopup() {
            const popup = opened();
            PaletteModel.dismiss();
            tryCompare(popup, "opened", false);
        }
    }
}
